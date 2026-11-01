import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CloudTests: XCTestCase {
    let msgs = [ChatMessage(role: .system, content: "sys"), ChatMessage(role: .user, content: "hi", images: [Data([1, 2, 3])]),
                ChatMessage(role: .assistant, content: "hello"), ChatMessage(role: .user, content: "again"),
                ChatMessage(role: .user, content: "<tool_response>x</tool_response>")]

    func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody!) as? [String: Any]) ?? [:]
    }

    func testOpenAIRequest() throws {
        let cfg = ProviderConfig(kind: .openRouter, model: "openai/gpt-5-mini")
        let r = try CloudRequestBuilder.chatRequest(config: cfg, apiKey: "k", messages: msgs, settings: GenerationSettings())
        XCTAssertEqual(r.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let b = body(r)
        let m = b["messages"] as! [[String: Any]]
        XCTAssertEqual(m.count, 5)
        let parts = m[1]["content"] as! [[String: Any]]
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        XCTAssertEqual(b["stream"] as? Bool, true)
    }

    func testOpenAIReasoningModelOmitsTemperature() throws {
        let r = try CloudRequestBuilder.chatRequest(config: ProviderConfig(kind: .openAI, model: "gpt-5"), apiKey: "k",
                                                    messages: msgs, settings: GenerationSettings())
        XCTAssertNil(body(r)["temperature"])
        XCTAssertNil(body(r)["max_tokens"])
    }

    func testAnthropicRequestMergesTurns() throws {
        let r = try CloudRequestBuilder.chatRequest(config: ProviderConfig(kind: .anthropic), apiKey: "k", messages: msgs, settings: GenerationSettings())
        XCTAssertEqual(r.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "k")
        let b = body(r)
        XCTAssertEqual(b["system"] as? String, "sys")
        let m = b["messages"] as! [[String: Any]]
        XCTAssertEqual(m.map { $0["role"] as! String }, ["user", "assistant", "user"])
        let first = m[0]["content"] as! [[String: Any]]
        XCTAssertEqual(first[0]["type"] as? String, "image")
        XCTAssertEqual((m[2]["content"] as! [[String: Any]]).count, 2)
    }

    func testGeminiRequest() throws {
        let r = try CloudRequestBuilder.chatRequest(config: ProviderConfig(kind: .gemini, model: "gemini-2.5-flash"), apiKey: "k",
                                                    messages: msgs, settings: GenerationSettings())
        XCTAssertTrue(r.url!.absoluteString.hasSuffix("/models/gemini-2.5-flash:streamGenerateContent?alt=sse"))
        let c = body(r)["contents"] as! [[String: Any]]
        XCTAssertEqual(c.map { $0["role"] as! String }, ["user", "model", "user"])
    }

    func testSSEAndDecoding() {
        let body = """
        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"مرحبا"}}

        : keep-alive

        data: {"choices":[{"delta":{"content":"Hi"}}]}

        data: [DONE]

        """
        let ev = SSEParser.events(in: body)
        XCTAssertEqual(ev.count, 3)
        XCTAssertEqual(CloudStreamDecoder.decode(ev[0], kind: .anthropic), .text("مرحبا"))
        XCTAssertEqual(CloudStreamDecoder.decode(ev[1], kind: .openAI), .text("Hi"))
        XCTAssertEqual(CloudStreamDecoder.decode(ev[2], kind: .openAI), .done)
        let g = SSEParser.Event(event: nil, data: "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"a\"},{\"text\":\"b\"}]}}]}")
        XCTAssertEqual(CloudStreamDecoder.decode(g, kind: .gemini), .text("ab"))
        let e = SSEParser.Event(event: nil, data: "{\"error\":{\"message\":\"bad key\"}}")
        XCTAssertEqual(CloudStreamDecoder.decode(e, kind: .openAI), .error("bad key"))
    }

    func testSSEWithCRLF() {
        let body = "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}\r\n\r\n"
        let r = try? MCPClient.parseResponse(Data(body.utf8), contentType: "text/event-stream", id: 7)
        XCTAssertEqual(r?["ok"] as? Bool, true)
    }

    func testParseModels() {
        let d = Data("{\"data\":[{\"id\":\"b\"},{\"id\":\"a\"}]}".utf8)
        XCTAssertEqual(CloudRequestBuilder.parseModels(d, kind: .openAI), ["a", "b"])
        let g = Data("{\"models\":[{\"name\":\"models/gemini-2.5-flash\"},{\"name\":\"models/embedding\"}]}".utf8)
        XCTAssertEqual(CloudRequestBuilder.parseModels(g, kind: .gemini), ["gemini-2.5-flash"])
    }
}

/// Fake MCP server speaking SSE like DeepWiki.
final class FakeMCPTransport: MCPTransport {
    var calls: [[String: Any]] = []
    func post(url: URL, body: Data, headers: [String: String]) async throws -> (Data, String, String?) {
        let req = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        calls.append(req)
        guard let id = req["id"] as? Int else { return (Data(), "application/json", nil) }
        let result: String
        switch req["method"] as! String {
        case "initialize":
            result = "{\"protocolVersion\":\"2025-06-18\",\"serverInfo\":{\"name\":\"Fake\"},\"capabilities\":{}}"
        case "tools/list":
            result = "{\"tools\":[{\"name\":\"ask-question\",\"description\":\"Ask about a repo\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"repoName\":{\"type\":\"string\",\"description\":\"owner/repo\"},\"question\":{\"type\":\"string\"}},\"required\":[\"repoName\"]}}]}"
        default:
            let args = (req["params"] as! [String: Any])["arguments"] as! [String: Any]
            result = "{\"content\":[{\"type\":\"text\",\"text\":\"answer for \(args["repoName"]!)\"}]}"
        }
        let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(result)}\n\n"
        return (Data(sse.utf8), "text/event-stream", "sess-1")
    }
}

final class MCPTests: XCTestCase {
    func testListAndCallThroughAgentRegistry() async throws {
        let t = FakeMCPTransport()
        let client = MCPClient(config: MCPServerConfig(name: "Deep Wiki", url: "https://example.com/mcp"), headerValue: "Bearer x", transport: t)
        let tools = try await client.listTools()
        XCTAssertEqual(client.serverName, "Fake")
        XCTAssertEqual(tools.first?.name, "ask-question")
        XCTAssertEqual(tools.first?.parameters.map(\.name), ["question", "repoName"])
        XCTAssertEqual(tools.first?.parameters.first { $0.name == "repoName" }?.required, true)

        let reg = ToolRegistry()
        tools.forEach { reg.register(MCPRemoteTool(info: $0, client: client)) }
        XCTAssertEqual(reg.specs.first?.name, "mcp_deepwiki_ask_question")
        XCTAssertEqual(reg.specs(for: ["mcp_*"], allowNetwork: true).count, 1)
        XCTAssertEqual(reg.specs(for: ["mcp_*"], allowNetwork: false).count, 0)

        let out = try await reg.tool(named: "mcp_deepwiki_ask_question")!.run(["repoName": .string("a/b")])
        XCTAssertEqual(out, "answer for a/b")
        XCTAssertEqual(t.calls.map { $0["method"] as! String }, ["initialize", "notifications/initialized", "tools/list", "tools/call"])
    }

    func testRPCError() {
        let d = Data("{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"nope\"}}".utf8)
        XCTAssertThrowsError(try MCPClient.parseResponse(d, contentType: "application/json", id: 3))
    }

    func testResultTextIsError() {
        XCTAssertEqual(MCPClient.resultText(["content": [["type": "text", "text": "x"]], "isError": true]), "خطأ من الأداة: x")
    }
}

final class MemoryAndHTMLTests: XCTestCase {
    func testMemoryDedupAndPrompt() {
        let m = MemoryStore(fileName: nil)
        XCTAssertTrue(m.add("يسكن في جدة"))
        XCTAssertFalse(m.add("يسكن في جده"))
        XCTAssertTrue(m.add("يحب القهوة العربية"))
        XCTAssertEqual(m.search("القهوه").first?.text, "يحب القهوة العربية")
        XCTAssertTrue(m.promptBlock().contains("يسكن في جدة"))
    }

    func testHTMLExtract() {
        let html = "<html><head><title>عنوان &amp; صفحة</title><style>.a{}</style></head><body><nav>menu</nav><script>var x=1</script><h1>مرحبا</h1><p>فقرة&nbsp;أولى</p><ul><li>بند</li></ul></body></html>"
        let r = HTMLText.extract(html)
        XCTAssertEqual(r.title, "عنوان & صفحة")
        XCTAssertTrue(r.text.contains("مرحبا"))
        XCTAssertTrue(r.text.contains("فقرة أولى"))
        XCTAssertTrue(r.text.contains("• بند"))
        XCTAssertFalse(r.text.contains("var x"))
        XCTAssertFalse(r.text.contains("menu"))
    }

    func testWildcardTools() {
        let r = ToolRegistry()
        CoreTools.register(into: r, knowledge: KnowledgeBase(fileName: nil), notes: NotesStore(fileName: nil), memory: MemoryStore(fileName: nil))
        XCTAssertEqual(r.specs(for: ["*"], allowNetwork: true).count, r.specs.count)
        XCTAssertEqual(r.specs(for: ["memory_*"], allowNetwork: true).map(\.name), ["memory_save", "memory_search"])
    }
}
