import Foundation

public enum Storage {
    /// Root folder for app data. Overridable for tests.
    public static var root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sanad", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    public static func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    public static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let d = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    public static func save<T: Encodable>(_ value: T, to name: String) {
        guard let d = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? d.write(to: url(name), options: [.atomic, .completeFileProtection])
    }
}

public struct KnowledgeDocument: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var chunks: [String]
    public var addedAt: Date
    public var characterCount: Int

    public init(id: UUID = UUID(), title: String, text: String, addedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.chunks = TextChunker.chunk(text)
        self.addedAt = addedAt
        self.characterCount = text.count
    }
}

public struct KnowledgeHit: Equatable, Sendable {
    public var documentTitle: String
    public var documentID: UUID
    public var chunk: String
    public var score: Double
}

/// Local document store with BM25 retrieval. Thread-safe via a serial lock.
public final class KnowledgeBase {
    public static let shared = KnowledgeBase(fileName: "knowledge.json")

    private let fileName: String?
    private let lock = NSLock()
    private var docs: [KnowledgeDocument]
    private var index = BM25Index()
    private var map: [(doc: Int, chunk: Int)] = []

    public init(fileName: String?) {
        self.fileName = fileName
        self.docs = fileName.flatMap { Storage.load([KnowledgeDocument].self, from: $0) } ?? []
        rebuild()
    }

    public var documents: [KnowledgeDocument] { lock.lock(); defer { lock.unlock() }; return docs }

    @discardableResult
    public func add(title: String, text: String) -> KnowledgeDocument {
        let d = KnowledgeDocument(title: title, text: text)
        lock.lock(); docs.append(d); rebuildLocked(); persistLocked(); lock.unlock()
        return d
    }

    public func remove(id: UUID) {
        lock.lock(); docs.removeAll { $0.id == id }; rebuildLocked(); persistLocked(); lock.unlock()
    }

    public func removeAll() {
        lock.lock(); docs.removeAll(); rebuildLocked(); persistLocked(); lock.unlock()
    }

    public func search(_ query: String, limit: Int = 4) -> [KnowledgeHit] {
        lock.lock(); defer { lock.unlock() }
        return index.search(query, limit: limit).map { h in
            let m = map[h.index]
            let d = docs[m.doc]
            return KnowledgeHit(documentTitle: d.title, documentID: d.id, chunk: d.chunks[m.chunk], score: h.score)
        }
    }

    public func document(titled title: String) -> KnowledgeDocument? {
        let n = ArabicText.normalize(title)
        return documents.first { ArabicText.normalize($0.title) == n }
            ?? documents.first { ArabicText.normalize($0.title).contains(n) }
    }

    private func rebuild() { lock.lock(); rebuildLocked(); lock.unlock() }

    private func rebuildLocked() {
        index = BM25Index()
        map = []
        for (di, d) in docs.enumerated() {
            for (ci, c) in d.chunks.enumerated() {
                index.add(d.title + "\n" + c)
                map.append((di, ci))
            }
        }
    }

    private func persistLocked() {
        if let f = fileName { Storage.save(docs, to: f) }
    }
}

public struct Note: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var body: String
    public var date: Date = Date()
    public init(title: String, body: String) { self.title = title; self.body = body }
}

public final class NotesStore {
    public static let shared = NotesStore(fileName: "notes.json")
    private let fileName: String?
    private let lock = NSLock()
    private var items: [Note]

    public init(fileName: String?) {
        self.fileName = fileName
        items = fileName.flatMap { Storage.load([Note].self, from: $0) } ?? []
    }

    public var notes: [Note] { lock.lock(); defer { lock.unlock() }; return items.sorted { $0.date > $1.date } }

    public func add(_ n: Note) {
        lock.lock(); items.append(n); if let f = fileName { Storage.save(items, to: f) }; lock.unlock()
    }

    public func remove(id: UUID) {
        lock.lock(); items.removeAll { $0.id == id }; if let f = fileName { Storage.save(items, to: f) }; lock.unlock()
    }

    public func removeAll() {
        lock.lock(); items.removeAll(); if let f = fileName { Storage.save(items, to: f) }; lock.unlock()
    }

    public func search(_ q: String) -> [Note] {
        let idx = BM25Index(documents: notes.map { $0.title + "\n" + $0.body })
        let all = notes
        if q.trimmingCharacters(in: .whitespaces).isEmpty { return Array(all.prefix(10)) }
        return idx.search(q, limit: 5).map { all[$0.index] }
    }
}
