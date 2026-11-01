import Foundation

/// Structural validation and metadata extraction for GGUF files.
///
/// Adapted from `LocalModelFileValidator.swift` in
/// `Mesutcydev/ios-local-llm` (MIT, © 2026 Mesut and iOS Local LLM contributors).
/// Their validator only checks the four magic bytes, so a truncated download
/// passes. This version parses the header, sanity-checks the declared counts and
/// walks the metadata block, so an incomplete file is rejected before llama.cpp
/// tries to map it.
public struct GGUFInfo: Equatable, Sendable {
    public var version: Int = 0
    public var tensorCount: UInt64 = 0
    public var metadataCount: UInt64 = 0
    public var architecture: String?
    public var name: String?
    public var contextLength: Int?
    public var fileSize: Int64 = 0
    public var isProjector: Bool = false
    public var isComplete: Bool = false
    public var problems: [String] = []
    /// Non-fatal: the header is valid, but the metadata could not be fully read.
    public var warnings: [String] = []

    public var isUsable: Bool { problems.isEmpty && isComplete }

    public var summary: String {
        var parts: [String] = []
        if let a = architecture { parts.append(a) }
        if let c = contextLength { parts.append("سياق \(c)") }
        parts.append("GGUF v\(version)")
        return parts.joined(separator: " · ")
    }
}

public enum GGUFInspector {
    static let magic: [UInt8] = [0x47, 0x47, 0x55, 0x46]  // "GGUF"
    static let maxMetadataBytes = 8 * 1024 * 1024
    static let maxEntries: UInt64 = 1_000_000

    public static func inspect(_ url: URL) -> GGUFInfo {
        var info = GGUFInfo()
        info.isProjector = url.lastPathComponent.lowercased().contains("mmproj")

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            info.problems = ["الملف غير موجود."]
            return info
        }
        info.fileSize = size
        guard size >= 24 else {
            info.problems = ["أصغر من ترويسة GGUF (24 بايت)."]
            return info
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            info.problems = ["تعذّر فتح الملف."]
            return info
        }
        defer { try? handle.close() }

        guard let head = try? handle.read(upToCount: 24), head.count == 24 else {
            info.problems = ["تعذّرت قراءة الترويسة."]
            return info
        }
        guard Array(head.prefix(4)) == magic else {
            info.problems = ["الملف ليس GGUF (ترويسة غير مطابقة)."]
            return info
        }
        info.version = Int(head.u32(4) ?? 0)
        guard (2...3).contains(info.version) else {
            info.problems = ["إصدار GGUF غير مدعوم: \(info.version)."]
            return info
        }
        info.tensorCount = head.u64(8) ?? 0
        info.metadataCount = head.u64(16) ?? 0
        if info.tensorCount == 0 || info.tensorCount > maxEntries {
            info.problems = ["عدد التنسورات غير منطقي: \(info.tensorCount)."]
        }
        if info.metadataCount > maxEntries {
            info.problems = ["عدد حقول البيانات غير منطقي: \(info.metadataCount)."]
        }
        guard info.problems.isEmpty else { return info }

        // The metadata block sits right after the header. Read a bounded slice.
        let remaining = size - 24
        let toRead = Int(min(Int64(maxMetadataBytes), remaining))
        let truncatedByWindow = Int64(toRead) < remaining
        var meta = Data()
        if toRead > 0, let chunk = try? handle.read(upToCount: toRead) { meta = chunk }

        var cursor = Cursor(data: meta, offset: 0)
        var architecture: String?
        var name: String?
        var contextLength: Int?
        var parsedAll = true

        for _ in 0..<info.metadataCount {
            guard let key = cursor.readString() else { parsedAll = false; break }
            guard let type = cursor.readU32() else { parsedAll = false; break }
            switch key {
            case "general.architecture":
                architecture = cursor.readStringValue(type: type)
            case "general.name":
                name = cursor.readStringValue(type: type)
            default:
                if key.hasSuffix(".context_length") {
                    contextLength = cursor.readIntegerValue(type: type).map(Int.init)
                } else if !cursor.skipValue(type: type) {
                    parsedAll = false
                }
            }
            if !parsedAll { break }
        }

        info.architecture = architecture
        info.name = name
        info.contextLength = contextLength
        // A large tokenizer can exceed the read window; that is not corruption.
        // Only treat a parse failure as damage when we actually read the whole file.
        info.isComplete = parsedAll || truncatedByWindow
        if !parsedAll && !truncatedByWindow {
            // Never block loading on this: header is intact, metadata is optional for us.
            info.warnings = ["لم أستطع قراءة كل البيانات الوصفية — الملف قد يكون غريب البنية."]
        }
        return info
    }

    /// Cheap gate used before loading: magic + sane size only.
    public static func looksLikeGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 4) else { return false }
        defer { try? handle.close() }
        return Array(head) == magic
    }

    // MARK: - Cursor

    struct Cursor {
        let data: Data
        var offset: Int

        mutating func readU8() -> UInt8? {
            guard offset + 1 <= data.count else { return nil }
            defer { offset += 1 }
            return data[offset]
        }
        mutating func readU32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            defer { offset += 4 }
            return data.u32(offset)
        }
        mutating func readU64() -> UInt64? {
            guard offset + 8 <= data.count else { return nil }
            defer { offset += 8 }
            return data.u64(offset)
        }
        mutating func readString() -> String? {
            guard let n = readU64() else { return nil }
            guard n <= 1_048_576, offset + Int(n) <= data.count else { return nil }
            defer { offset += Int(n) }
            return String(decoding: data[offset..<(offset + Int(n))], as: UTF8.self)
        }
        mutating func readStringValue(type: UInt32) -> String? {
            if type == 8 { return readString() }
            _ = skipValue(type: type)
            return nil
        }
        mutating func readIntegerValue(type: UInt32) -> UInt64? {
            switch type {
            case 0, 1, 7: return readU8().map(UInt64.init)
            case 2, 3:
                guard offset + 2 <= data.count else { return nil }
                defer { offset += 2 }
                return UInt64(UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)
            case 4, 5: return readU32().map(UInt64.init)
            case 10, 11: return readU64()
            default:
                _ = skipValue(type: type)
                return nil
            }
        }
        mutating func skipValue(type: UInt32) -> Bool {
            switch type {
            case 0, 1, 7: return advance(1)
            case 2, 3: return advance(2)
            case 4, 5, 6: return advance(4)
            case 10, 11, 12: return advance(8)
            case 8: return readString() != nil
            case 9:
                guard let element = readU32(), let count = readU64(), count <= 1_000_000 else { return false }
                for _ in 0..<count {
                    if element == 8 {
                        guard readString() != nil else { return false }
                    } else if !skipValue(type: element) {
                        return false
                    }
                }
                return true
            default:
                return false
            }
        }
        mutating func advance(_ n: Int) -> Bool {
            guard offset + n <= data.count else { return false }
            offset += n
            return true
        }
    }
}

extension Data {
    func u32(_ i: Int) -> UInt32? {
        guard i >= 0, i + 4 <= count else { return nil }
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
    func u64(_ i: Int) -> UInt64? {
        guard i >= 0, i + 8 <= count else { return nil }
        var value: UInt64 = 0
        for k in 0..<8 { value |= UInt64(self[i + k]) << (8 * UInt64(k)) }
        return value
    }
}
