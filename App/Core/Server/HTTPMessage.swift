import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Parses a complete request from a buffer. Returns nil if more bytes are needed.
    public static func parse(_ data: Data) -> (HTTPRequest, Int)? {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = data.range(of: sep) else { return nil }
        guard let head = String(data: data[data.startIndex..<r.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = r.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return nil }
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: length)]
        var path = String(first[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        let consumed = data.distance(from: data.startIndex, to: bodyStart) + length
        return (HTTPRequest(method: String(first[0]).uppercased(), path: path, headers: headers, body: Data(body)), consumed)
    }
}

public enum HTTPResponse {
    static let cors = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\n"

    public static func make(status: Int, json: Any) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        return make(status: status, contentType: "application/json; charset=utf-8", body: body)
    }

    public static func make(status: Int, contentType: String, body: Data) -> Data {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        head += cors + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    public static func streamHead(contentType: String) -> Data {
        Data("HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nCache-Control: no-cache\r\n\(cors)Connection: close\r\n\r\n".utf8)
    }

    public static func error(_ status: Int, _ message: String) -> Data {
        make(status: status, json: ["error": ["message": message, "type": "invalid_request_error"]] as [String: Any])
    }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}

/// Converts OpenAI / Ollama chat payloads into our message type.
public enum ChatPayload {
    public struct Parsed {
        public var messages: [ChatMessage]
        public var stream: Bool
        public var settings: GenerationSettings
    }

    public static func parse(_ body: Data, ollama: Bool = false) -> Parsed? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        var msgs: [ChatMessage] = []
        if let arr = obj["messages"] as? [[String: Any]] {
            for m in arr {
                let role = ChatRole(rawValue: (m["role"] as? String) ?? "user") ?? .user
                var text = ""
                if let s = m["content"] as? String { text = s }
                else if let parts = m["content"] as? [[String: Any]] {
                    text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                msgs.append(ChatMessage(role: role == .tool ? .user : role, content: text))
            }
        } else if let prompt = obj["prompt"] as? String {
            if let sys = obj["system"] as? String { msgs.append(ChatMessage(role: .system, content: sys)) }
            msgs.append(ChatMessage(role: .user, content: prompt))
        }
        guard !msgs.isEmpty else { return nil }
        var s = GenerationSettings()
        let opts = (obj["options"] as? [String: Any]) ?? obj
        if let t = opts["temperature"] as? Double { s.temperature = t }
        if let p = opts["top_p"] as? Double { s.topP = p }
        if let k = opts["top_k"] as? Int { s.topK = k }
        if let m = (opts["max_tokens"] ?? opts["num_predict"] ?? opts["max_completion_tokens"]) as? Int { s.maxTokens = max(1, min(m, 8192)) }
        let stream = (obj["stream"] as? Bool) ?? ollama // Ollama streams by default
        return Parsed(messages: msgs, stream: stream, settings: s)
    }
}
