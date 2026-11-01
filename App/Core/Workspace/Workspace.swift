import Foundation

/// A file or folder inside an agent workspace.
public struct FileNode: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String          // relative to the workspace root
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
    public var childCount: Int

    public init(path: String, name: String, isDirectory: Bool, size: Int64, modified: Date, childCount: Int = 0) {
        self.path = path; self.name = name; self.isDirectory = isDirectory
        self.size = size; self.modified = modified; self.childCount = childCount
    }
}

public struct WorkspaceSearchHit: Identifiable, Hashable, Sendable {
    public var id: String { "\(path)#\(line)" }
    public var path: String
    public var line: Int
    public var snippet: String
}

public enum WorkspaceError: LocalizedError, Equatable {
    case invalidPath
    case outsideRoot
    case notFound(String)
    case isDirectory
    case notDirectory
    case tooLarge(Int)
    case quotaExceeded
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPath: return "مسار غير صالح (لا يُسمح بـ .. أو المسارات المطلقة)."
        case .outsideRoot: return "المسار خارج مساحة العمل المسموح بها."
        case .notFound(let p): return "الملف غير موجود: \(p)"
        case .isDirectory: return "المسار مجلد وليس ملفاً."
        case .notDirectory: return "المسار ملف وليس مجلداً."
        case .tooLarge(let n): return "الملف أكبر من الحد المسموح (\(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)))."
        case .quotaExceeded: return "تجاوزت مساحة التخزين المسموح بها لمساحة العمل."
        case .encodingFailed: return "تعذّر ترميز الملف كنص UTF-8."
        }
    }
}

/// Sandboxed per-agent file store. Every path is validated against traversal and symlink escapes.
public final class WorkspaceStore {
    public static let shared = WorkspaceStore(root: Storage.root.appendingPathComponent("Workspaces", isDirectory: true))

    public let root: URL
    public let maxFileBytes: Int
    public let maxTotalBytes: Int64
    private let lock = NSLock()

    public init(root: URL, maxFileBytes: Int = 8 * 1024 * 1024, maxTotalBytes: Int64 = 512 * 1024 * 1024) {
        self.root = root
        self.maxFileBytes = maxFileBytes
        self.maxTotalBytes = maxTotalBytes
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Paths

    public func folder(for agentID: String) -> URL {
        let slug = Self.slug(agentID)
        return root.appendingPathComponent(slug.isEmpty ? "default" : slug, isDirectory: true)
    }

    @discardableResult
    public func ensureFolder(_ agentID: String) throws -> URL {
        let f = folder(for: agentID)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    static func slug(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        let s = raw.lowercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(s)).prefix(64).description
    }

    /// Resolves a relative path, rejecting traversal, absolute paths and symlink escapes.
    public func url(_ agentID: String, _ relative: String) throws -> URL {
        let base = try ensureFolder(agentID).standardizedFileURL
        let rel = try Self.normalize(relative)
        let candidate = base.appendingPathComponent(rel).standardizedFileURL
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard candidate.path == base.path || candidate.path.hasPrefix(basePath) else { throw WorkspaceError.outsideRoot }
        let resolvedBase = base.resolvingSymlinksInPath().path
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard resolvedParent == resolvedBase || resolvedParent.hasPrefix(resolvedBase + "/") || candidate.path == base.path else {
            throw WorkspaceError.outsideRoot
        }
        return candidate
    }

    static func normalize(_ relative: String) throws -> String {
        let trimmed = relative.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { throw WorkspaceError.invalidPath }
        if trimmed.contains("://") { throw WorkspaceError.invalidPath }
        var parts: [String] = []
        for raw in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            let c = String(raw)
            if c == "." { continue }
            if c == ".." { throw WorkspaceError.invalidPath }
            if c.utf8.count > 128 { throw WorkspaceError.invalidPath }
            if c.contains("\0") { throw WorkspaceError.invalidPath }
            parts.append(c)
        }
        return parts.joined(separator: "/")
    }

    // MARK: Read

    public func list(_ agentID: String, at relative: String = "") throws -> [FileNode] {
        let dir = try url(agentID, relative)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return [try node(for: dir, relative: relative)] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [FileNode] = []
        for n in names where !n.hasPrefix(".") {
            let child = dir.appendingPathComponent(n)
            let rel = relative.isEmpty ? n : relative + "/" + n
            if let node = try? node(for: child, relative: rel) { out.append(node) }
        }
        return out.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func node(for url: URL, relative: String) throws -> FileNode {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let isDir = values.isDirectory ?? false
        var count = 0
        if isDir { count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0 }
        return FileNode(path: relative, name: url.lastPathComponent, isDirectory: isDir,
                        size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? Date(),
                        childCount: count)
    }

    public func readData(_ agentID: String, _ relative: String) throws -> Data {
        let u = try url(agentID, relative)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { throw WorkspaceError.notFound(relative) }
        if isDir.boolValue { throw WorkspaceError.isDirectory }
        let attrs = try FileManager.default.attributesOfItem(atPath: u.path)
        if let size = attrs[.size] as? Int, size > maxFileBytes { throw WorkspaceError.tooLarge(maxFileBytes) }
        return try Data(contentsOf: u)
    }

    public func readText(_ agentID: String, _ relative: String) throws -> String {
        let data = try readData(agentID, relative)
        guard let s = String(data: data, encoding: .utf8) else { throw WorkspaceError.encodingFailed }
        return s
    }

    public func exists(_ agentID: String, _ relative: String) -> Bool {
        guard let u = try? url(agentID, relative) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    // MARK: Write

    @discardableResult
    public func write(_ agentID: String, _ relative: String, text: String) throws -> URL {
        try write(agentID, relative, data: Data(text.utf8))
    }

    @discardableResult
    public func write(_ agentID: String, _ relative: String, data: Data) throws -> URL {
        guard data.count <= maxFileBytes else { throw WorkspaceError.tooLarge(maxFileBytes) }
        lock.lock(); defer { lock.unlock() }
        let u = try url(agentID, relative)
        let base = folder(for: agentID)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if totalBytesLocked(base) + Int64(data.count) > maxTotalBytes { throw WorkspaceError.quotaExceeded }
        try data.write(to: u, options: [.atomic])
        return u
    }

    @discardableResult
    public func append(_ agentID: String, _ relative: String, text: String) throws -> URL {
        let existing = (try? readText(agentID, relative)) ?? ""
        return try write(agentID, relative, text: existing + text)
    }

    @discardableResult
    public func createFolder(_ agentID: String, _ relative: String) throws -> URL {
        let u = try url(agentID, relative)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    public func delete(_ agentID: String, _ relative: String) throws {
        let u = try url(agentID, relative)
        guard u.path != folder(for: agentID).path else { throw WorkspaceError.invalidPath }
        guard FileManager.default.fileExists(atPath: u.path) else { throw WorkspaceError.notFound(relative) }
        try FileManager.default.removeItem(at: u)
    }

    @discardableResult
    public func rename(_ agentID: String, _ relative: String, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix("."), trimmed != ".", trimmed != ".." else {
            throw WorkspaceError.invalidPath
        }
        let old = try url(agentID, relative)
        guard FileManager.default.fileExists(atPath: old.path) else { throw WorkspaceError.notFound(relative) }
        let parent = (relative as NSString).deletingLastPathComponent
        let newRel = parent.isEmpty ? trimmed : parent + "/" + trimmed
        let new = try url(agentID, newRel)
        try FileManager.default.moveItem(at: old, to: new)
        return new
    }

    // MARK: Search

    public func search(_ agentID: String, query: String, limit: Int = 40) throws -> [WorkspaceSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let base = try ensureFolder(agentID)
        var hits: [WorkspaceSearchHit] = []
        let needle = ArabicText.normalize(q)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return [] }
        for case let u as URL in walker {
            guard hits.count < limit else { break }
            let values = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { continue }
            if (values?.fileSize ?? 0) > 512 * 1024 { continue }
            guard let data = try? Data(contentsOf: u), let text = String(data: data, encoding: .utf8) else { continue }
            let rel = u.path.replacingOccurrences(of: base.path + "/", with: "")
            if ArabicText.normalize(rel).contains(needle) {
                hits.append(WorkspaceSearchHit(path: rel, line: 1, snippet: rel))
                continue
            }
            for (i, line) in text.components(separatedBy: .newlines).enumerated() {
                if ArabicText.normalize(line).contains(needle) {
                    hits.append(WorkspaceSearchHit(path: rel, line: i + 1, snippet: String(line.prefix(160))))
                    if hits.count >= limit { break }
                }
            }
        }
        return hits
    }

    // MARK: Storage

    public func totalBytes(_ agentID: String) -> Int64 { totalBytesLocked(folder(for: agentID)) }

    private func totalBytesLocked(_ dir: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in walker {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if v?.isDirectory == true { continue }
            total += Int64(v?.fileSize ?? 0)
        }
        return total
    }

    public func clear(_ agentID: String) throws {
        let f = folder(for: agentID)
        if FileManager.default.fileExists(atPath: f.path) { try FileManager.default.removeItem(at: f) }
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
    }

    /// Builds a ZIP of the whole workspace in the temporary directory.
    public func exportZip(_ agentID: String, name: String? = nil) throws -> URL {
        let base = try ensureFolder(agentID)
        var entries: [(String, Data)] = []
        if let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let u as URL in walker {
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey])
                let rel = u.path.replacingOccurrences(of: base.path + "/", with: "")
                if v?.isDirectory == true { continue }
                if let d = try? Data(contentsOf: u) { entries.append((rel, d)) }
            }
        }
        let fileName = (name ?? "workspace-\(agentID)") + ".zip"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: out)
        try ZipWriter.write(entries: entries, to: out, root: name ?? "workspace")
        return out
    }
}
