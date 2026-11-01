import Foundation

/// Long-term memory: facts about the user the assistant remembers across chats.
public struct MemoryItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var text: String
    public var date: Date = Date()
    public init(text: String) { self.text = text }
}

public final class MemoryStore {
    public static let shared = MemoryStore(fileName: "memory.json")
    private let fileName: String?
    private let lock = NSLock()
    private var items: [MemoryItem]

    public init(fileName: String?) {
        self.fileName = fileName
        items = fileName.flatMap { Storage.load([MemoryItem].self, from: $0) } ?? []
    }

    public var all: [MemoryItem] { lock.lock(); defer { lock.unlock() }; return items }

    /// Adds a fact unless a near-duplicate already exists. Returns false for duplicates.
    @discardableResult
    public func add(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let n = ArabicText.normalize(t)
        lock.lock(); defer { lock.unlock() }
        if items.contains(where: { ArabicText.normalize($0.text) == n }) { return false }
        items.append(MemoryItem(text: t))
        persist()
        return true
    }

    public func remove(id: UUID) { lock.lock(); items.removeAll { $0.id == id }; persist(); lock.unlock() }
    public func removeAll() { lock.lock(); items.removeAll(); persist(); lock.unlock() }

    public func search(_ q: String, limit: Int = 8) -> [MemoryItem] {
        let snapshot = all
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return Array(snapshot.suffix(limit)) }
        let idx = BM25Index(documents: snapshot.map(\.text))
        return idx.search(q, limit: limit).map { snapshot[$0.index] }
    }

    /// Block injected into system prompts.
    public func promptBlock(limit: Int = 30) -> String {
        let items = all.suffix(limit)
        guard !items.isEmpty else { return "" }
        return "\n\n# ما تعرفه عن المستخدم (ذاكرة طويلة المدى)\n" + items.map { "- \($0.text)" }.joined(separator: "\n")
    }

    private func persist() { if let f = fileName { Storage.save(items, to: f) } }
}

/// Extracts readable text from an HTML page.
public enum HTMLText {
    public static func extract(_ html: String, limit: Int = 12000) -> (title: String, text: String) {
        var s = html
        let title = s.slice(between: "<title", and: "</title>").map { t -> String in
            guard let gt = t.firstIndex(of: ">") else { return "" }
            return decode(String(t[t.index(after: gt)...])).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "form", "iframe"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<li[^>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decode(s)
        s = s.replacingOccurrences(of: "[ \\t\\u00A0]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > limit { s = String(s.prefix(limit)) + "\n…(مقتطع)" }
        return (title, s)
    }

    static func decode(_ s: String) -> String {
        var r = s
        for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&lt;": "<", "&gt;": ">", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–"] {
            r = r.replacingOccurrences(of: k, with: v)
        }
        return r
    }
}

extension String {
    func slice(between a: String, and b: String) -> String? {
        guard let r1 = range(of: a, options: .caseInsensitive),
              let r2 = range(of: b, options: .caseInsensitive, range: r1.upperBound..<endIndex) else { return nil }
        return String(self[r1.upperBound..<r2.lowerBound])
    }
}
