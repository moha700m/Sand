import Foundation
import JavaScriptCore

/// Streams completions from a cloud provider (OpenAI-compatible, Anthropic, Gemini).
final class CloudBackend: LLMBackend, @unchecked Sendable {
    let config: ProviderConfig
    private let apiKey: String

    init(config: ProviderConfig, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
    }

    var isReady: Bool { !apiKey.isEmpty || config.kind == .custom }

    func generate(messages: [ChatMessage], settings: GenerationSettings, stop: [String],
                  onToken: @escaping (String) -> Bool) async throws -> (text: String, stats: GenerationStats) {
        guard isReady else { throw CloudError.missingKey }
        let req = try CloudRequestBuilder.chatRequest(config: config, apiKey: apiKey, messages: messages, settings: settings)
        let start = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status >= 400 {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 2000 { break } }
            let msg = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? body
            throw CloudError.http(status, msg)
        }
        var parser = SSEParser()
        var text = ""
        var emitted = 0
        var chunks = 0
        var stopped = false
        let hold = stop.map(\.count).max() ?? 0

        func handle(_ e: SSEParser.Event) throws -> Bool {
            switch CloudStreamDecoder.decode(e, kind: config.kind) {
            case .text(let t):
                text += t
                chunks += 1
                if let hit = stop.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                    text = String(text[..<hit.lowerBound])
                    stopped = true
                }
                let safe = stopped ? text.count : max(emitted, text.count - hold)
                if safe > emitted {
                    let piece = String(text.dropFirst(emitted).prefix(safe - emitted))
                    emitted = safe
                    if !onToken(piece) { return false }
                }
                return !stopped
            case .done: return false
            case .error(let m): throw CloudError.http(status, m)
            case .none: return true
            }
        }

        loop: for try await line in bytes.lines {
            if Task.isCancelled { break }
            // URLSession's `lines` drops blank lines, so treat each data line as a complete event.
            if let e = parser.feed(line) { if try !handle(e) { break loop } }
            if line.hasPrefix("data:"), let e = parser.feed("") { if try !handle(e) { break loop } }
        }
        if let e = parser.finish() { _ = try handle(e) }
        if emitted < text.count { _ = onToken(String(text.dropFirst(emitted))) }
        let secs = Date().timeIntervalSince(start)
        return (text, GenerationStats(promptTokens: 0, generatedTokens: max(chunks, text.count / 4), seconds: secs))
    }

    static func fetchModels(config: ProviderConfig, apiKey: String) async throws -> [String] {
        guard let req = CloudRequestBuilder.modelsRequest(config: config, apiKey: apiKey) else { throw CloudError.badURL }
        let (d, r) = try await URLSession.shared.data(for: req)
        if let h = r as? HTTPURLResponse, h.statusCode >= 400 { throw CloudError.http(h.statusCode, String(decoding: d, as: UTF8.self)) }
        return CloudRequestBuilder.parseModels(d, kind: config.kind)
    }
}

/// URLSession transport for MCP Streamable HTTP.
struct URLSessionMCPTransport: MCPTransport {
    func post(url: URL, body: Data, headers: [String: String]) async throws -> (Data, String, String?) {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = body
        r.timeoutInterval = 90
        headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw MCPError.noResponse }
        if h.statusCode == 401 || h.statusCode == 403 { throw MCPError.rpc("غير مصرح (\(h.statusCode)) — تحقق من مفتاح الخادم") }
        if h.statusCode >= 400 { throw MCPError.rpc("HTTP \(h.statusCode): \(String(decoding: d.prefix(300), as: UTF8.self))") }
        return (d, h.value(forHTTPHeaderField: "Content-Type") ?? "", h.value(forHTTPHeaderField: "Mcp-Session-Id"))
    }
}

/// Manages remote MCP servers and registers their tools with the agent.
@MainActor
final class MCPManager: ObservableObject {
    struct Status: Equatable { var connected = false; var toolCount = 0; var error: String?; var busy = false }

    @Published var servers: [MCPServerConfig]
    @Published var status: [String: Status] = [:]
    private var clients: [String: MCPClient] = [:]
    private let registry: ToolRegistry

    init(registry: ToolRegistry) {
        self.registry = registry
        servers = Storage.load([MCPServerConfig].self, from: "mcp.json") ?? MCPServerConfig.presets
    }

    func save() { Storage.save(servers, to: "mcp.json") }

    func upsert(_ s: MCPServerConfig, header: String?) {
        if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s } else { servers.append(s) }
        if let header { header.isEmpty ? Keychain.delete(s.keychainKey) : Keychain.set(header, for: s.keychainKey) }
        save()
        Task { await connect(s) }
    }

    func remove(_ s: MCPServerConfig) {
        registry.unregister(prefix: "mcp_\(s.slug)_")
        servers.removeAll { $0.id == s.id }
        clients[s.id] = nil
        status[s.id] = nil
        Keychain.delete(s.keychainKey)
        save()
    }

    func setEnabled(_ s: MCPServerConfig, _ on: Bool) {
        guard let i = servers.firstIndex(where: { $0.id == s.id }) else { return }
        servers[i].enabled = on
        save()
        if on { Task { await connect(servers[i]) } } else {
            registry.unregister(prefix: "mcp_\(s.slug)_")
            status[s.id] = Status()
        }
    }

    func connectAll() async {
        for s in servers where s.enabled { await connect(s) }
    }

    func connect(_ s: MCPServerConfig) async {
        guard s.enabled else { return }
        status[s.id] = Status(busy: true)
        let client = MCPClient(config: s, headerValue: Keychain.get(s.keychainKey), transport: URLSessionMCPTransport())
        do {
            let tools = try await client.listTools()
            registry.unregister(prefix: "mcp_\(s.slug)_")
            tools.forEach { registry.register(MCPRemoteTool(info: $0, client: client)) }
            clients[s.id] = client
            status[s.id] = Status(connected: true, toolCount: tools.count)
        } catch {
            status[s.id] = Status(connected: false, error: error.localizedDescription)
        }
    }

    var totalTools: Int { status.values.reduce(0) { $0 + $1.toolCount } }
}

/// Sandboxed JavaScript execution (code interpreter) using JavaScriptCore.
enum JSRunner {
    static func run(_ code: String, timeout: TimeInterval = 8) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                await withCheckedContinuation { cont in
                    Thread.detachNewThread {
                        cont.resume(returning: execute(code))
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ToolError("انتهت مهلة التنفيذ (\(Int(timeout)) ث) — تحقق من وجود حلقة لا نهائية")
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
    }

    private static func execute(_ code: String) -> String {
        guard let ctx = JSContext() else { return "تعذّر إنشاء بيئة JavaScript" }
        var logs: [String] = []
        let log: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            logs.append(args.map { v -> String in
                if v.isObject, let json = ctx.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [v, NSNull(), 2]),
                   !json.isUndefined { return json.toString() }
                return v.toString()
            }.joined(separator: " "))
        }
        let console = JSValue(newObjectIn: ctx)!
        console.setObject(log, forKeyedSubscript: "log" as NSString)
        console.setObject(log, forKeyedSubscript: "error" as NSString)
        console.setObject(log, forKeyedSubscript: "info" as NSString)
        ctx.setObject(console, forKeyedSubscript: "console" as NSString)
        var exception: String?
        ctx.exceptionHandler = { _, e in exception = e?.toString() }
        let result = ctx.evaluateScript(code)
        var out = logs.joined(separator: "\n")
        if let r = result, !r.isUndefined, !r.isNull {
            out += (out.isEmpty ? "" : "\n") + "=> " + (r.toString() ?? "")
        }
        if let exception { out += (out.isEmpty ? "" : "\n") + "خطأ: \(exception)" }
        if out.count > 6000 { out = String(out.prefix(6000)) + "\n…(مقتطع)" }
        return out.isEmpty ? "(تم التنفيذ بدون مخرجات — استخدم console.log)" : out
    }
}
