import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cloud model providers (optional, bring-your-own-key) for heavy tasks.
public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, anthropic, gemini, openRouter, groq, deepSeek, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic Claude"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .groq: return "Groq"
        case .deepSeek: return "DeepSeek"
        case .custom: return "مخصص (متوافق OpenAI)"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .custom: return "http://192.168.1.10:1234/v1"
        }
    }

    public var suggestedModels: [String] {
        switch self {
        case .openAI: return ["gpt-5", "gpt-5-mini", "gpt-4.1", "gpt-4o-mini"]
        case .anthropic: return ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]
        case .gemini: return ["gemini-2.5-pro", "gemini-2.5-flash"]
        case .openRouter: return ["openrouter/auto", "anthropic/claude-sonnet-5-5", "openai/gpt-5-mini", "deepseek/deepseek-chat"]
        case .groq: return ["llama-3.3-70b-versatile", "qwen/qwen3-32b"]
        case .deepSeek: return ["deepseek-chat", "deepseek-reasoner"]
        case .custom: return ["local-model"]
        }
    }

    public var supportsVision: Bool { self != .deepSeek && self != .groq }

    var isOpenAICompatible: Bool { self != .anthropic && self != .gemini }
}

public struct ProviderConfig: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var kind: ProviderKind
    public var name: String
    public var baseURL: String
    public var model: String

    public init(id: String = UUID().uuidString, kind: ProviderKind, name: String? = nil, baseURL: String? = nil, model: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.title
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.model = model ?? kind.suggestedModels.first ?? ""
    }

    public var displayName: String { "\(name) · \(model)" }
    public var keychainKey: String { "provider-key-\(id)" }
}

public enum CloudError: LocalizedError {
    case missingKey, badURL, http(Int, String)
    public var errorDescription: String? {
        switch self {
        case .missingKey: return "أضف مفتاح API لهذا المزود من الإعدادات ← مزودو السحابة."
        case .badURL: return "رابط المزود غير صالح."
        case .http(let c, let m): return "خطأ من المزود (\(c)): \(m.prefix(300))"
        }
    }
}

/// Builds streaming chat requests for each provider family.
public enum CloudRequestBuilder {
    public static func chatRequest(config: ProviderConfig, apiKey: String, messages: [ChatMessage],
                                   settings: GenerationSettings) throws -> URLRequest {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var req: URLRequest
        var body: [String: Any]
        switch config.kind {
        case .anthropic:
            guard let url = URL(string: base + "/messages") else { throw CloudError.badURL }
            req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
            body = ["model": config.model, "max_tokens": max(256, settings.maxTokens), "stream": true,
                    "messages": anthropicMessages(messages)]
            if !system.isEmpty { body["system"] = system }
            body["temperature"] = min(1, settings.temperature)
        case .gemini:
            guard let url = URL(string: "\(base)/models/\(config.model):streamGenerateContent?alt=sse") else { throw CloudError.badURL }
            req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
            body = ["contents": geminiContents(messages),
                    "generationConfig": ["temperature": settings.temperature, "topP": settings.topP,
                                         "maxOutputTokens": max(256, settings.maxTokens)] as [String: Any]]
            if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        default:
            guard let url = URL(string: base + "/chat/completions") else { throw CloudError.badURL }
            req = URLRequest(url: url)
            if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            if config.kind == .openRouter {
                req.setValue("https://github.com/moha700m/rafeeq-ios", forHTTPHeaderField: "HTTP-Referer")
                req.setValue("Sanad AI", forHTTPHeaderField: "X-Title")
            }
            body = ["model": config.model, "stream": true, "messages": openAIMessages(messages)]
            let reasoning = config.kind == .openAI && (config.model.hasPrefix("gpt-5") || config.model.hasPrefix("o"))
            if !reasoning {
                body["temperature"] = settings.temperature
                body["max_tokens"] = max(256, settings.maxTokens)
            }
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 120
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    public static func modelsRequest(config: ProviderConfig, apiKey: String) -> URLRequest? {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/models") else { return nil }
        var r = URLRequest(url: url)
        switch config.kind {
        case .anthropic:
            r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            r.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        default:
            if !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        }
        r.timeoutInterval = 20
        return r
    }

    public static func parseModels(_ data: Data, kind: ProviderKind) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if kind == .gemini, let arr = obj["models"] as? [[String: Any]] {
            return arr.compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
                .filter { $0.contains("gemini") }.sorted()
        }
        let arr = (obj["data"] as? [[String: Any]]) ?? []
        return arr.compactMap { $0["id"] as? String }.sorted()
    }

    // MARK: message conversion

    static func openAIMessages(_ msgs: [ChatMessage]) -> [[String: Any]] {
        msgs.map { m in
            let role = m.role == .tool ? "user" : m.role.rawValue
            guard let imgs = m.images, !imgs.isEmpty else { return ["role": role, "content": m.content] }
            var parts: [[String: Any]] = [["type": "text", "text": m.content]]
            for d in imgs {
                parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + d.base64EncodedString()]])
            }
            return ["role": role, "content": parts]
        }
    }

    /// Anthropic requires alternating user/assistant turns starting with user, system separate.
    static func anthropicMessages(_ msgs: [ChatMessage]) -> [[String: Any]] {
        var out: [(role: String, parts: [[String: Any]])] = []
        for m in msgs where m.role != .system {
            let role = m.role == .assistant ? "assistant" : "user"
            var parts: [[String: Any]] = []
            for d in m.images ?? [] {
                parts.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": d.base64EncodedString()]])
            }
            if !m.content.isEmpty { parts.append(["type": "text", "text": m.content]) }
            if parts.isEmpty { continue }
            if let last = out.last, last.role == role {
                out[out.count - 1].parts += parts
            } else {
                out.append((role, parts))
            }
        }
        if out.first?.role == "assistant" { out.insert(("user", [["type": "text", "text": "…"]]), at: 0) }
        return out.map { ["role": $0.role, "content": $0.parts] }
    }

    static func geminiContents(_ msgs: [ChatMessage]) -> [[String: Any]] {
        var out: [(role: String, parts: [[String: Any]])] = []
        for m in msgs where m.role != .system {
            let role = m.role == .assistant ? "model" : "user"
            var parts: [[String: Any]] = []
            for d in m.images ?? [] {
                parts.append(["inline_data": ["mime_type": "image/jpeg", "data": d.base64EncodedString()]])
            }
            if !m.content.isEmpty { parts.append(["text": m.content]) }
            if parts.isEmpty { continue }
            if let last = out.last, last.role == role { out[out.count - 1].parts += parts } else { out.append((role, parts)) }
        }
        return out.map { ["role": $0.role, "parts": $0.parts] }
    }
}

/// Incremental Server-Sent-Events parser.
public struct SSEParser {
    public struct Event: Equatable { public var event: String?; public var data: String }
    private var event: String?
    private var data: [String] = []

    public init() {}

    /// Feed one line (without trailing newline). Returns an event when a blank line completes it.
    public mutating func feed(_ line: String) -> Event? {
        let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if l.isEmpty {
            defer { event = nil; data = [] }
            return data.isEmpty ? nil : Event(event: event, data: data.joined(separator: "\n"))
        }
        if l.hasPrefix(":") { return nil }
        if l.hasPrefix("event:") { event = l.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        else if l.hasPrefix("data:") {
            var v = String(l.dropFirst(5))
            if v.hasPrefix(" ") { v.removeFirst() }
            data.append(v)
        }
        return nil
    }

    /// Flushes a pending event at end of stream.
    public mutating func finish() -> Event? { feed("") }

    /// Parses a whole SSE body.
    public static func events(in body: String) -> [Event] {
        var p = SSEParser()
        var out: [Event] = []
        // Split on any newline grapheme: "\r\n" is a single Character in Swift.
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            if let e = p.feed(String(line)) { out.append(e) }
        }
        if let e = p.finish() { out.append(e) }
        return out
    }
}

public enum CloudStreamDecoder {
    public enum Chunk: Equatable { case text(String), done, error(String), none }

    public static func decode(_ e: SSEParser.Event, kind: ProviderKind) -> Chunk {
        if e.data == "[DONE]" { return .done }
        guard let d = e.data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return .none }
        if let err = obj["error"] as? [String: Any] { return .error((err["message"] as? String) ?? "\(err)") }
        switch kind {
        case .anthropic:
            let type = obj["type"] as? String
            if type == "content_block_delta", let delta = obj["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta", let t = delta["text"] as? String { return .text(t) }
            if type == "message_stop" { return .done }
            return .none
        case .gemini:
            let cands = obj["candidates"] as? [[String: Any]]
            let parts = (cands?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            let text = parts?.compactMap { p -> String? in
                if p["thought"] as? Bool == true { return nil }
                return p["text"] as? String
            }.joined() ?? ""
            return text.isEmpty ? .none : .text(text)
        default:
            let choice = (obj["choices"] as? [[String: Any]])?.first
            if let delta = choice?["delta"] as? [String: Any], let t = delta["content"] as? String, !t.isEmpty { return .text(t) }
            return .none
        }
    }
}
