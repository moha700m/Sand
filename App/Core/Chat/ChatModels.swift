import Foundation

public enum ChatRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var role: ChatRole
    public var content: String
    public var date: Date
    /// Agent trace for assistant messages produced by an agent run.
    public var agentSteps: [AgentStep]?
    /// Generation stats (tokens/sec) for assistant messages.
    public var tokensPerSecond: Double?
    public var tokenCount: Int?
    /// JPEG images attached to a user message (sent to vision-capable cloud models).
    public var images: [Data]?
    /// Which model produced an assistant message (e.g. "Qwen3 1.7B" or "Claude · claude-sonnet-5-5").
    public var modelName: String?

    public init(id: UUID = UUID(), role: ChatRole, content: String, date: Date = Date(),
                agentSteps: [AgentStep]? = nil, tokensPerSecond: Double? = nil, tokenCount: Int? = nil,
                images: [Data]? = nil, modelName: String? = nil) {
        self.images = images
        self.modelName = modelName
        self.id = id
        self.role = role
        self.content = content
        self.date = date
        self.agentSteps = agentSteps
        self.tokensPerSecond = tokensPerSecond
        self.tokenCount = tokenCount
    }
}

public struct Conversation: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var messages: [ChatMessage]
    public var personaID: String
    public var agentID: String?
    public var modelID: String?
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String = "محادثة جديدة", messages: [ChatMessage] = [],
                personaID: String = Persona.general.id, agentID: String? = nil, modelID: String? = nil,
                updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.messages = messages
        self.personaID = personaID
        self.agentID = agentID
        self.modelID = modelID
        self.updatedAt = updatedAt
    }
}

public struct GenerationSettings: Codable, Equatable, Sendable {
    public var temperature: Double = 0.7
    public var topP: Double = 0.9
    public var topK: Int = 40
    public var repeatPenalty: Double = 1.1
    public var maxTokens: Int = 1024
    public var contextLength: Int = 4096
    public var seed: UInt32 = 0xFFFF_FFFF
    /// Hide `<think>…</think>` reasoning blocks (Qwen3 etc.) from the visible reply.
    public var hideThinking: Bool = true
    /// Let reasoning models (Qwen3) think before answering. Slower but smarter.
    public var enableThinking: Bool = false

    public init() {}

    public static let agent: GenerationSettings = {
        var s = GenerationSettings()
        s.temperature = 0.3
        s.maxTokens = 768
        return s
    }()
}

public struct GenerationStats: Sendable, Equatable {
    public var promptTokens: Int
    public var generatedTokens: Int
    public var seconds: Double
    public var tokensPerSecond: Double { seconds > 0 ? Double(generatedTokens) / seconds : 0 }
    public init(promptTokens: Int = 0, generatedTokens: Int = 0, seconds: Double = 0) {
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.seconds = seconds
    }
}

/// Anything that can turn a list of chat messages into a streamed completion.
public protocol LLMBackend: AnyObject {
    var isReady: Bool { get }
    /// Generates a reply. `onToken` is called with each new text piece; return `false` to stop early.
    func generate(messages: [ChatMessage],
                  settings: GenerationSettings,
                  stop: [String],
                  onToken: @escaping (String) -> Bool) async throws -> (text: String, stats: GenerationStats)
}

public enum LLMError: LocalizedError {
    case noModelLoaded
    case loadFailed(String)
    case contextOverflow
    case decodeFailed(Int32)
    case insufficientMemory(needed: UInt64, available: UInt64)

    public var errorDescription: String? {
        switch self {
        case .noModelLoaded: return "لا يوجد نموذج محمّل. حمّل نموذجاً من تبويب النماذج."
        case .loadFailed(let s): return "تعذّر تحميل النموذج: \(s)"
        case .contextOverflow: return "المحادثة أطول من سياق النموذج. ابدأ محادثة جديدة أو زد طول السياق."
        case .decodeFailed(let c): return "فشل التوليد (رمز \(c))."
        case .insufficientMemory(let n, let a):
            let f = ByteCountFormatter()
            return "الذاكرة غير كافية: يحتاج \(f.string(fromByteCount: Int64(n))) والمتاح \(f.string(fromByteCount: Int64(a)))."
        }
    }
}

public enum ThinkingFilter {
    /// Removes `<think>…</think>` blocks; an unterminated block is removed to the end.
    public static func strip(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>") {
            if let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
