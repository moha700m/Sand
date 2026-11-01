import Foundation
import Network

/// OpenAI- and Ollama-compatible HTTP server over the LAN, backed by the loaded on-device model.
public final class LocalAPIServer {
    public private(set) var isRunning = false
    public private(set) var port: UInt16 = 8080
    public var onLog: ((String) -> Void)?
    public var onStateChange: ((Bool) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sanad.api")
    private let backend: () -> LLMBackend?
    private let modelName: () -> String
    private let apiKey: () -> String?
    private let gate = GenerationGate()

    public init(backend: @escaping () -> LLMBackend?, modelName: @escaping () -> String, apiKey: @escaping () -> String?) {
        self.backend = backend
        self.modelName = modelName
        self.apiKey = apiKey
    }

    public func start(port: UInt16) throws {
        stop()
        guard let p = NWEndpoint.Port(rawValue: port) else { throw ToolError("منفذ غير صالح") }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: p)
        l.service = NWListener.Service(name: "Sanad AI", type: "_http._tcp")
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.isRunning = true
                self.log("الخادم يعمل على المنفذ \(port)")
                DispatchQueue.main.async { self.onStateChange?(true) }
            case .failed(let e):
                self.isRunning = false
                self.log("فشل الخادم: \(e.localizedDescription)")
                DispatchQueue.main.async { self.onStateChange?(false) }
            case .cancelled:
                self.isRunning = false
                DispatchQueue.main.async { self.onStateChange?(false) }
            default: break
            }
        }
        self.port = port
        listener = l
        l.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func log(_ s: String) { DispatchQueue.main.async { self.onLog?(s) } }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > 8 << 20 { self.send(c, HTTPResponse.error(400, "payload too large")); return }
            if let (req, _) = HTTPRequest.parse(buf) {
                Task { await self.handle(req, on: c) }
            } else if done || err != nil {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func send(_ c: NWConnection, _ d: Data, close: Bool = true) {
        c.send(content: d, completion: .contentProcessed { _ in if close { c.cancel() } })
    }

    private func authorized(_ r: HTTPRequest) -> Bool {
        guard let key = apiKey(), !key.isEmpty else { return true }
        return r.header("authorization") == "Bearer \(key)" || r.header("x-api-key") == key
    }

    private func handle(_ r: HTTPRequest, on c: NWConnection) async {
        log("\(r.method) \(r.path)")
        if r.method == "OPTIONS" { send(c, HTTPResponse.make(status: 204, contentType: "text/plain", body: Data())); return }
        if r.path == "/" || r.path == "/health" {
            send(c, HTTPResponse.make(status: 200, json: ["status": "ok", "model": modelName(), "app": "Sanad AI"] as [String: Any])); return
        }
        guard authorized(r) else { send(c, HTTPResponse.error(401, "invalid API key")); return }
        let created = Int(Date().timeIntervalSince1970)
        switch (r.method, r.path) {
        case ("GET", "/v1/models"):
            send(c, HTTPResponse.make(status: 200, json: ["object": "list", "data": [["id": modelName(), "object": "model", "created": created, "owned_by": "sanad"] as [String: Any]]] as [String: Any]))
        case ("GET", "/api/tags"):
            send(c, HTTPResponse.make(status: 200, json: ["models": [["name": modelName(), "model": modelName()]]] as [String: Any]))
        case ("POST", "/v1/chat/completions"):
            await chat(r, c, ollama: false)
        case ("POST", "/api/chat"), ("POST", "/api/generate"):
            await chat(r, c, ollama: true, generate: r.path == "/api/generate")
        default:
            send(c, HTTPResponse.error(404, "unknown route \(r.path)"))
        }
    }

    private func chat(_ r: HTTPRequest, _ c: NWConnection, ollama: Bool, generate: Bool = false) async {
        guard let p = ChatPayload.parse(r.body, ollama: ollama) else { send(c, HTTPResponse.error(400, "invalid JSON body")); return }
        guard let b = backend(), b.isReady else { send(c, HTTPResponse.error(503, "no model loaded in Sanad AI")); return }
        let id = "chatcmpl-\(UUID().uuidString.prefix(12))"
        let model = modelName()
        let created = Int(Date().timeIntervalSince1970)

        await gate.run {
            if p.stream {
                self.send(c, HTTPResponse.streamHead(contentType: ollama ? "application/x-ndjson" : "text/event-stream"), close: false)
                do {
                    let (_, stats) = try await b.generate(messages: p.messages, settings: p.settings, stop: []) { piece in
                        let obj: [String: Any]
                        if ollama {
                            obj = generate ? ["model": model, "response": piece, "done": false] as [String: Any]
                                : ["model": model, "message": ["role": "assistant", "content": piece], "done": false] as [String: Any]
                        } else {
                            obj = ["id": id, "object": "chat.completion.chunk", "created": created, "model": model,
                                   "choices": [["index": 0, "delta": ["content": piece], "finish_reason": NSNull()] as [String: Any]]] as [String: Any]
                        }
                        self.send(c, Self.frame(obj, sse: !ollama), close: false)
                        return true
                    }
                    if ollama {
                        var end: [String: Any] = ["model": model, "done": true, "eval_count": stats.generatedTokens]
                        if generate { end["response"] = "" } else { end["message"] = ["role": "assistant", "content": ""] }
                        self.send(c, Self.frame(end, sse: false))
                    } else {
                        let end: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": model,
                                                  "choices": [["index": 0, "delta": [String: Any](), "finish_reason": "stop"] as [String: Any]]]
                        self.send(c, Self.frame(end, sse: true) + Data("data: [DONE]\n\n".utf8))
                    }
                } catch {
                    self.send(c, Data("data: {\"error\":\"\(error.localizedDescription)\"}\n\n".utf8))
                }
            } else {
                do {
                    let (text, stats) = try await b.generate(messages: p.messages, settings: p.settings, stop: []) { _ in true }
                    let clean = p.settings.hideThinking ? ThinkingFilter.strip(text) : text
                    let json: [String: Any]
                    if ollama {
                        json = generate ? ["model": model, "response": clean, "done": true] as [String: Any]
                            : ["model": model, "message": ["role": "assistant", "content": clean], "done": true] as [String: Any]
                    } else {
                        json = ["id": id, "object": "chat.completion", "created": created, "model": model,
                                "choices": [["index": 0, "message": ["role": "assistant", "content": clean], "finish_reason": "stop"] as [String: Any]],
                                "usage": ["prompt_tokens": stats.promptTokens, "completion_tokens": stats.generatedTokens,
                                          "total_tokens": stats.promptTokens + stats.generatedTokens]] as [String: Any]
                    }
                    self.send(c, HTTPResponse.make(status: 200, json: json))
                } catch {
                    self.send(c, HTTPResponse.error(500, error.localizedDescription))
                }
            }
        }
    }

    static func frame(_ obj: [String: Any], sse: Bool) -> Data {
        let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return sse ? Data("data: ".utf8) + d + Data("\n\n".utf8) : d + Data("\n".utf8)
    }
}

/// Serialises generations: the on-device model can only run one at a time.
public actor GenerationGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func run(_ body: @escaping () async -> Void) async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        await body()
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
