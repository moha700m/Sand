import Foundation

/// Per-model generation overrides. `nil` means "use the app default".
public struct ModelTuning: Codable, Equatable, Sendable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var maxTokens: Int?
    public var contextLength: Int?
    public var systemSuffix: String

    public init(temperature: Double? = nil, topP: Double? = nil, topK: Int? = nil,
                maxTokens: Int? = nil, contextLength: Int? = nil, systemSuffix: String = "") {
        self.temperature = temperature; self.topP = topP; self.topK = topK
        self.maxTokens = maxTokens; self.contextLength = contextLength; self.systemSuffix = systemSuffix
    }

    public func applied(to base: GenerationSettings) -> GenerationSettings {
        var s = base
        if let t = temperature { s.temperature = t }
        if let p = topP { s.topP = p }
        if let k = topK { s.topK = k }
        if let m = maxTokens { s.maxTokens = m }
        if let c = contextLength { s.contextLength = c }
        return s
    }
}

public final class ModelTuningStore {
    public static let shared = ModelTuningStore(fileName: "modeltuning.json")
    private let fileName: String?
    private let lock = NSLock()
    private var items: [String: ModelTuning]

    public init(fileName: String?) {
        self.fileName = fileName
        items = fileName.flatMap { Storage.load([String: ModelTuning].self, from: $0) } ?? [:]
    }

    public func tuning(for id: String) -> ModelTuning {
        lock.lock(); defer { lock.unlock() }
        return items[id] ?? ModelTuning()
    }

    public func set(_ tuning: ModelTuning, for id: String) {
        lock.lock(); items[id] = tuning; lock.unlock()
        persist()
    }

    public func remove(_ id: String) {
        lock.lock(); items[id] = nil; lock.unlock()
        persist()
    }

    private func persist() {
        guard let f = fileName else { return }
        lock.lock(); let snapshot = items; lock.unlock()
        Storage.save(snapshot, to: f)
    }
}
