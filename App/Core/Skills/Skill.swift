import Foundation

public enum SkillCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case programming, research, writing, documents, automation, data, business, aiDev, ios

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .programming: return "برمجة"
        case .research: return "بحث"
        case .writing: return "كتابة"
        case .documents: return "مستندات"
        case .automation: return "أتمتة"
        case .data: return "تحليل بيانات"
        case .business: return "أعمال"
        case .aiDev: return "تطوير AI"
        case .ios: return "تطوير iOS"
        }
    }

    public var icon: String {
        switch self {
        case .programming: return "chevron.left.forwardslash.chevron.right"
        case .research: return "magnifyingglass"
        case .writing: return "text.alignleft"
        case .documents: return "doc.text"
        case .automation: return "gearshape.2"
        case .data: return "chart.bar.xaxis"
        case .business: return "briefcase"
        case .aiDev: return "brain"
        case .ios: return "iphone"
        }
    }
}

/// A reusable instruction package (SKILL.md) an agent can load on demand.
public struct SkillPackage: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var version: String
    public var category: SkillCategory
    public var tools: [String]
    public var inputs: [String]
    public var body: String
    public var enabled: Bool
    public var builtIn: Bool
    public var createdAt: Date

    public init(id: String, name: String, summary: String, version: String = "1.0.0",
                category: SkillCategory, tools: [String] = [], inputs: [String] = [],
                body: String, enabled: Bool = true, builtIn: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.summary = summary; self.version = version
        self.category = category; self.tools = tools; self.inputs = inputs
        self.body = body; self.enabled = enabled; self.builtIn = builtIn; self.createdAt = createdAt
    }

    /// Text injected into an agent's system prompt when this skill is selected.
    public var promptBlock: String {
        """
        <skill id="\(id)" name="\(name)">
        \(body)
        </skill>
        """
    }
}

public enum SkillParser {
    /// Parses `---` front matter followed by a markdown body.
    public static func parse(_ text: String, fallbackName: String = "مهارة") -> SkillPackage? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var meta: [String: String] = [:]
        var body = normalized

        if normalized.hasPrefix("---") {
            let afterFirst = normalized.dropFirst(3)
            if let endRange = afterFirst.range(of: "\n---") {
                let front = String(afterFirst[..<endRange.lowerBound])
                body = String(afterFirst[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                for line in front.components(separatedBy: "\n") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, !t.hasPrefix("#"), let sep = t.firstIndex(of: ":") else { continue }
                    let key = t[..<sep].trimmingCharacters(in: .whitespaces).lowercased()
                    var value = t[t.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                    if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                        value = String(value.dropFirst().dropLast())
                    }
                    meta[key] = value
                }
            }
        }

        let name = meta["name"] ?? firstHeading(body) ?? fallbackName
        guard !body.isEmpty else { return nil }
        let id = slug(meta["id"] ?? name)
        guard !id.isEmpty else { return nil }

        return SkillPackage(
            id: id,
            name: name,
            summary: meta["description"] ?? meta["summary"] ?? String(body.prefix(140)),
            version: meta["version"] ?? "1.0.0",
            category: SkillCategory(rawValue: meta["category"] ?? "") ?? .automation,
            tools: list(meta["tools"]),
            inputs: list(meta["inputs"]),
            body: body
        )
    }

    public static func render(_ s: SkillPackage) -> String {
        var out = "---\n"
        out += "id: \(s.id)\n"
        out += "name: \(s.name)\n"
        out += "description: \(s.summary)\n"
        out += "version: \(s.version)\n"
        out += "category: \(s.category.rawValue)\n"
        if !s.tools.isEmpty { out += "tools: [\(s.tools.joined(separator: ", "))]\n" }
        if !s.inputs.isEmpty { out += "inputs: [\(s.inputs.joined(separator: ", "))]\n" }
        out += "---\n\n"
        out += s.body
        return out
    }

    static func list(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        let inner = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func firstHeading(_ body: String) -> String? {
        for line in body.components(separatedBy: "\n") where line.hasPrefix("# ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    public static func slug(_ raw: String) -> String {
        let map: [Character: String] = ["ا": "a", "أ": "a", "إ": "a", "آ": "a", "ب": "b", "ت": "t", "ث": "th",
                                         "ج": "j", "ح": "h", "خ": "kh", "د": "d", "ذ": "dh", "ر": "r", "ز": "z",
                                         "س": "s", "ش": "sh", "ص": "s", "ض": "d", "ط": "t", "ظ": "z", "ع": "a",
                                         "غ": "gh", "ف": "f", "ق": "q", "ك": "k", "ل": "l", "م": "m", "ن": "n",
                                         "ه": "h", "و": "w", "ي": "y", "ى": "a", "ة": "h", "ء": "2"]
        var out = ""
        for ch in raw.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
            else if let mapped = map[ch] { out.append(contentsOf: mapped) }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48).description
    }
}

public final class SkillStore {
    public static let shared = SkillStore(fileName: "skills.json")
    private let fileName: String?
    private let lock = NSLock()
    private var items: [SkillPackage]

    public init(fileName: String?) {
        self.fileName = fileName
        let loaded = fileName.flatMap { Storage.load([SkillPackage].self, from: $0) } ?? []
        let customIDs = Set(loaded.map(\.id))
        items = loaded + BuiltInSkills.all.filter { !customIDs.contains($0.id) }
        if loaded.isEmpty { persist() }
    }

    public var all: [SkillPackage] { lock.lock(); defer { lock.unlock() }; return items }
    public var enabled: [SkillPackage] { all.filter(\.enabled) }

    public func skill(id: String) -> SkillPackage? { all.first { $0.id == id } }

    @discardableResult
    public func upsert(_ skill: SkillPackage) -> SkillPackage {
        var s = skill
        if s.id.isEmpty { s.id = SkillParser.slug(s.name) }
        lock.lock()
        if let i = items.firstIndex(where: { $0.id == s.id }) {
            if items[i].builtIn { s.builtIn = true }
            items[i] = s
        } else {
            items.append(s)
        }
        lock.unlock()
        persist()
        return s
    }

    @discardableResult
    public func installFromText(_ text: String, fallbackName: String = "مهارة مستوردة") -> SkillPackage? {
        guard let parsed = SkillParser.parse(text, fallbackName: fallbackName) else { return nil }
        return upsert(parsed)
    }

    public func setEnabled(_ id: String, _ on: Bool) {
        lock.lock()
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].enabled = on }
        lock.unlock()
        persist()
    }

    public func delete(_ id: String) {
        lock.lock(); items.removeAll { $0.id == id && !$0.builtIn }; lock.unlock()
        persist()
    }

    public func export(_ id: String) -> URL? {
        guard let s = skill(id: id) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(s.id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("SKILL.md")
        try? SkillParser.render(s).write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Imports a folder containing SKILL.md (or the first .md inside).
    @discardableResult
    public func importFolder(_ url: URL) throws -> SkillPackage {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let direct = url.appendingPathComponent("SKILL.md")
        var file = direct
        if !FileManager.default.fileExists(atPath: direct.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            guard let md = contents.first(where: { $0.pathExtension.lowercased() == "md" }) else {
                throw ToolError("المجلد لا يحتوي SKILL.md")
            }
            file = md
        }
        let text = try String(contentsOf: file, encoding: .utf8)
        guard let parsed = SkillParser.parse(text, fallbackName: url.lastPathComponent) else {
            throw ToolError("تعذّر تحليل SKILL.md")
        }
        return upsert(parsed)
    }

    /// Prompt block for the given skills, capped so a large library cannot eat the context.
    public func promptBlock(for ids: [String], maxChars: Int = 6000) -> String {
        let chosen = ids.isEmpty ? [] : all.filter { ids.contains($0.id) && $0.enabled }
        guard !chosen.isEmpty else { return "" }
        var out = "\n\n# مهارات مفعّلة\n"
        for s in chosen {
            let block = s.promptBlock
            if out.count + block.count > maxChars { break }
            out += block + "\n"
        }
        return out
    }

    private func persist() {
        guard let f = fileName else { return }
        let snapshot = all
        Storage.save(snapshot, to: f)
    }
}
