import Foundation

/// A remote MCP server reachable over the Streamable HTTP transport.
public struct MCPServerConfig: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    /// Optional header, e.g. "Authorization: Bearer xyz". Stored value lives in Keychain.
    public var headerName: String
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, url: String, headerName: String = "Authorization", enabled: Bool = true) {
        self.id = id; self.name = name; self.url = url; self.headerName = headerName; self.enabled = enabled
    }

    public var keychainKey: String { "mcp-header-\(id)" }

    /// Short slug used to namespace tool names, e.g. "deepwiki".
    public var slug: String {
        let s = name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        let str = String(String.UnicodeScalarView(s))
        return str.isEmpty ? "srv" + String(id.prefix(4)).lowercased() : String(str.prefix(16))
    }

    public static let presets: [MCPServerConfig] = [
        MCPServerConfig(id: "preset-deepwiki", name: "DeepWiki", url: "https://mcp.deepwiki.com/mcp", enabled: false),
    ]
}

public struct MCPToolInfo: Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: [ToolParameter]
}

/// Sends one HTTP POST and returns (body, content-type, session id).
public protocol MCPTransport {
    func post(url: URL, body: Data, headers: [String: String]) async throws -> (Data, String, String?)
}

public enum MCPError: LocalizedError {
    case badURL, noResponse, rpc(String)
    public var errorDescription: String? {
        switch self {
        case .badURL: return "رابط خادم MCP غير صالح"
        case .noResponse: return "لم يرد خادم MCP"
        case .rpc(let m): return "خطأ MCP: \(m)"
        }
    }
}

/// Minimal MCP client: initialize → tools/list → tools/call (JSON-RPC 2.0, Streamable HTTP).
public final class MCPClient {
    public let config: MCPServerConfig
    private let transport: MCPTransport
    private let headerValue: String?
    private var sessionID: String?
    private var nextID = 1
    private var initialized = false
    public private(set) var serverName: String?
    public private(set) var instructions: String?

    public static let protocolVersion = "2025-06-18"

    public init(config: MCPServerConfig, headerValue: String?, transport: MCPTransport) {
        self.config = config
        self.headerValue = headerValue
        self.transport = transport
    }

    public func initialize() async throws {
        let r = try await request("initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Sanad AI", "version": "2.0"],
        ])
        serverName = (r["serverInfo"] as? [String: Any])?["name"] as? String
        instructions = r["instructions"] as? String
        initialized = true
        try? await notify("notifications/initialized")
    }

    public func listTools() async throws -> [MCPToolInfo] {
        if !initialized { try await initialize() }
        var all: [MCPToolInfo] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let r = try await request("tools/list", params: params)
            all += Self.parseTools(r)
            cursor = r["nextCursor"] as? String
        } while cursor != nil && all.count < 500
        return all
    }

    public func callTool(_ name: String, arguments: ToolArguments) async throws -> String {
        if !initialized { try await initialize() }
        let argsData = try JSONEncoder().encode(arguments)
        let args = (try JSONSerialization.jsonObject(with: argsData)) as? [String: Any] ?? [:]
        let r = try await request("tools/call", params: ["name": name, "arguments": args])
        return Self.resultText(r)
    }

    // MARK: JSON-RPC

    private func headers() -> [String: String] {
        var h = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                 "MCP-Protocol-Version": Self.protocolVersion]
        if let sessionID { h["Mcp-Session-Id"] = sessionID }
        if let v = headerValue, !v.isEmpty { h[config.headerName.isEmpty ? "Authorization" : config.headerName] = v }
        return h
    }

    private func notify(_ method: String) async throws {
        guard let url = URL(string: config.url) else { throw MCPError.badURL }
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method])
        _ = try await transport.post(url: url, body: body, headers: headers())
    }

    private func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: config.url) else { throw MCPError.badURL }
        let id = nextID
        nextID += 1
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params] as [String: Any])
        let (data, type, session) = try await transport.post(url: url, body: body, headers: headers())
        if let session { sessionID = session }
        return try Self.parseResponse(data, contentType: type, id: id)
    }

    // MARK: parsing (static for testing)

    public static func parseResponse(_ data: Data, contentType: String, id: Int) throws -> [String: Any] {
        var candidates: [Data] = []
        if contentType.contains("event-stream") {
            let text = String(decoding: data, as: UTF8.self)
            candidates = SSEParser.events(in: text).compactMap { $0.data.data(using: .utf8) }
        } else {
            candidates = [data]
        }
        for c in candidates {
            guard let obj = try? JSONSerialization.jsonObject(with: c) as? [String: Any] else { continue }
            let rid = (obj["id"] as? Int) ?? Int((obj["id"] as? String) ?? "")
            guard rid == id else { continue }
            if let err = obj["error"] as? [String: Any] { throw MCPError.rpc((err["message"] as? String) ?? "\(err)") }
            return (obj["result"] as? [String: Any]) ?? [:]
        }
        throw MCPError.noResponse
    }

    public static func parseTools(_ result: [String: Any]) -> [MCPToolInfo] {
        let tools = (result["tools"] as? [[String: Any]]) ?? []
        return tools.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let schema = (t["inputSchema"] as? [String: Any]) ?? [:]
            let props = (schema["properties"] as? [String: Any]) ?? [:]
            let required = Set((schema["required"] as? [String]) ?? [])
            let params = props.keys.sorted().map { k -> ToolParameter in
                let p = (props[k] as? [String: Any]) ?? [:]
                return ToolParameter(k, (p["type"] as? String) ?? "string",
                                     ((p["description"] as? String) ?? "").replacingOccurrences(of: "\"", with: "'"),
                                     required: required.contains(k))
            }
            let desc = ((t["description"] as? String) ?? (t["title"] as? String) ?? name)
            return MCPToolInfo(name: name, description: String(desc.prefix(400)).replacingOccurrences(of: "\"", with: "'")
                .replacingOccurrences(of: "\n", with: " "), parameters: params)
        }
    }

    public static func resultText(_ result: [String: Any]) -> String {
        var parts: [String] = []
        for c in (result["content"] as? [[String: Any]]) ?? [] {
            switch c["type"] as? String {
            case "text": if let t = c["text"] as? String { parts.append(t) }
            case "resource":
                if let r = c["resource"] as? [String: Any], let t = r["text"] as? String { parts.append(t) }
            case "image": parts.append("[صورة]")
            default: break
            }
        }
        if parts.isEmpty, let s = result["structuredContent"],
           let d = try? JSONSerialization.data(withJSONObject: s), let t = String(data: d, encoding: .utf8) {
            parts.append(t)
        }
        let text = parts.joined(separator: "\n")
        return (result["isError"] as? Bool == true) ? "خطأ من الأداة: " + text : (text.isEmpty ? "(لا يوجد ناتج)" : text)
    }
}

/// Exposes one remote MCP tool to the agent.
public final class MCPRemoteTool: AgentTool {
    public let spec: ToolSpec
    private let client: MCPClient
    private let remoteName: String

    public init(info: MCPToolInfo, client: MCPClient) {
        self.client = client
        self.remoteName = info.name
        let safe = info.name.replacingOccurrences(of: "-", with: "_")
        self.spec = ToolSpec(name: "mcp_\(client.config.slug)_\(safe)", title: "\(client.config.name): \(info.name)",
                             icon: "puzzlepiece.extension", description: info.description,
                             parameters: info.parameters, requiresConfirmation: false, usesNetwork: true)
    }

    public func run(_ args: ToolArguments) async throws -> String {
        try await client.callTool(remoteName, arguments: args)
    }
}
