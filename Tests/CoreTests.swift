import XCTest

final class HijriTests: XCTestCase {
    func testRamadan1445StartedOn11March2024() {
        let h = Hijri.toHijri(.init(year: 2024, month: 3, day: 11))
        XCTAssertEqual(h, .init(year: 1445, month: 9, day: 1))
    }

    func testRoundTrip() {
        let g = Hijri.DateParts(year: 2026, month: 11, day: 1)
        let h = Hijri.toHijri(g)!
        XCTAssertEqual(Hijri.toGregorian(h), g)
    }

    func testParseArabicDigits() {
        XCTAssertEqual(Hijri.parse("١٤٤٧-٠٩-٠١"), .init(year: 1447, month: 9, day: 1))
        XCTAssertEqual(Hijri.parse("11/3/2024"), .init(year: 2024, month: 3, day: 11))
    }

    func testDescribeContainsBothCalendars() {
        let d = Hijri.date(gregorian: .init(year: 2024, month: 3, day: 11))!
        let s = Hijri.describe(d)
        XCTAssertTrue(s.contains("رمضان"))
        XCTAssertTrue(s.contains("مارس"))
        XCTAssertTrue(s.contains("الاثنين"))
    }
}

final class PrayerTimesTests: XCTestCase {
    func testRiyadhOrderAndRanges() {
        let date = Hijri.date(gregorian: .init(year: 2026, month: 6, day: 21))!
        let t = PrayerTimes.compute(date: date, latitude: 24.7136, longitude: 46.6753)
        let times = t.ordered.map(\.time)
        XCTAssertEqual(times, times.sorted(), "prayers must be in chronological order")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = Hijri.riyadh
        func hm(_ d: Date) -> Double { let c = cal.dateComponents([.hour, .minute], from: d); return Double(c.hour!) + Double(c.minute!) / 60 }
        // Riyadh, summer solstice (published Umm al-Qura ≈ Fajr 3:34, Dhuhr 11:58, Maghrib 18:43)
        XCTAssertEqual(hm(t.fajr), 3.57, accuracy: 0.25)
        XCTAssertEqual(hm(t.dhuhr), 11.97, accuracy: 0.15)
        XCTAssertEqual(hm(t.maghrib), 18.72, accuracy: 0.2)
        XCTAssertEqual(t.isha.timeIntervalSince(t.maghrib), 90 * 60, accuracy: 1)
    }

    func testRamadanIshaIs120Minutes() {
        let date = Hijri.date(hijri: .init(year: 1447, month: 9, day: 10))!
        let t = PrayerTimes.compute(date: date, latitude: 21.4225, longitude: 39.8262)
        XCTAssertEqual(t.isha.timeIntervalSince(t.maghrib), 120 * 60, accuracy: 1)
    }

    func testQiblaFromRiyadh() {
        let b = Qibla.bearing(latitude: 24.7136, longitude: 46.6753)
        XCTAssertEqual(b, 244, accuracy: 3)
        XCTAssertEqual(Qibla.distanceKm(latitude: 24.7136, longitude: 46.6753), 790, accuracy: 40)
    }

    func testCityLookup() {
        XCTAssertEqual(PrayerTimes.city(named: "جده")?.name, "جدة")
        XCTAssertEqual(PrayerTimes.city(named: "الرياض")?.name, "الرياض")
    }
}

final class FinanceTests: XCTestCase {
    func testVATAdd() {
        let b = VAT.add(to: 100)
        XCTAssertEqual(b.vat, 15)
        XCTAssertEqual(b.gross, 115)
    }

    func testVATExtract() {
        let b = VAT.extract(from: 4599)
        XCTAssertEqual(b.net, Decimal(string: "3999.13"))
        XCTAssertEqual(b.vat, Decimal(string: "599.87"))
    }

    func testZakatDue() {
        var i = Zakat.Input()
        i.cash = 120_000
        i.goldPricePerGram = 410
        let r = Zakat.compute(i)
        XCTAssertEqual(r.nisab, 34_850)
        XCTAssertTrue(r.isDue)
        XCTAssertEqual(r.zakat, 3_000)
    }

    func testZakatBelowNisab() {
        var i = Zakat.Input()
        i.cash = 10_000
        i.goldPricePerGram = 410
        XCTAssertFalse(Zakat.compute(i).isDue)
        XCTAssertEqual(Zakat.compute(i).zakat, 0)
    }

    func testEndOfService() {
        XCTAssertEqual(EndOfService.compute(monthlyWage: 9000, years: 7, reason: .terminatedByEmployer), 40_500)
        XCTAssertEqual(EndOfService.compute(monthlyWage: 9000, years: 7, reason: .resignation), 27_000)
        XCTAssertEqual(EndOfService.compute(monthlyWage: 9000, years: 1, reason: .resignation), 0)
        XCTAssertEqual(EndOfService.compute(monthlyWage: 9000, years: 3, reason: .resignation), 4_500)
    }

    func testArabicDecimalParsing() {
        XCTAssertEqual(Decimal(arabic: "١٢٠٬٠٠٠"), 120_000)
        XCTAssertEqual(Decimal(arabic: "1,250.5"), Decimal(string: "1250.5"))
    }
}

final class CalculatorTests: XCTestCase {
    func testPrecedence() throws {
        XCTAssertEqual(try Calculator.evaluate("2+3*4"), 14)
        XCTAssertEqual(try Calculator.evaluate("(2+3)*4"), 20)
        XCTAssertEqual(try Calculator.evaluate("2^10"), 1024)
        XCTAssertEqual(try Calculator.evaluate("-3+5"), 2)
    }

    func testDecimalExactness() throws {
        XCTAssertEqual(try Calculator.evaluate("0.1+0.2"), Decimal(string: "0.3"))
    }

    func testPercentAndArabic() throws {
        XCTAssertEqual(try Calculator.evaluate("200*15%"), 30)
        XCTAssertEqual(try Calculator.evaluate("١٠٠÷٤"), 25)
        XCTAssertEqual(try Calculator.evaluate("10%3"), 1)
    }

    func testErrors() {
        XCTAssertThrowsError(try Calculator.evaluate("1/0"))
        XCTAssertThrowsError(try Calculator.evaluate("2+"))
        XCTAssertThrowsError(try Calculator.evaluate("(1+2"))
    }
}

final class KnowledgeTests: XCTestCase {
    func testNormalization() {
        XCTAssertEqual(ArabicText.normalize("أَحْمَد"), "احمد")
        XCTAssertEqual(ArabicText.normalize("مدرسة"), "مدرسه")
        XCTAssertEqual(ArabicText.normalize("على"), "علي")
    }

    func testBM25RanksRelevantDocFirst() {
        let idx = BM25Index(documents: [
            "مدة العقد سنة ميلادية تبدأ من يناير وقيمة الإيجار 36 ألف ريال",
            "مواقيت الصلاة في مدينة الرياض حسب تقويم أم القرى",
            "The quick brown fox jumps over the lazy dog",
        ])
        let hits = idx.search("كم قيمة الإيجار في العقد؟")
        XCTAssertEqual(hits.first?.index, 0)
        XCTAssertEqual(idx.search("الصلاة").first?.index, 1)
        XCTAssertEqual(idx.search("fox").first?.index, 2)
    }

    func testKnowledgeBaseSearchReturnsTitle() {
        let kb = KnowledgeBase(fileName: nil)
        kb.add(title: "عقد الإيجار", text: "التأمين 2000 ريال يسترد عند نهاية العقد")
        kb.add(title: "وصفة كبسة", text: "رز بسمتي ودجاج وبهارات الكبسة")
        XCTAssertEqual(kb.search("التأمين").first?.documentTitle, "عقد الإيجار")
        XCTAssertEqual(kb.search("الكبسه").first?.documentTitle, "وصفة كبسة")
    }

    func testChunker() {
        let text = (0..<50).map { "فقرة رقم \($0) فيها بعض الكلام المفيد للاختبار." }.joined(separator: "\n\n")
        let chunks = TextChunker.chunk(text, size: 300, overlap: 50)
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 400 })
    }
}

final class ToolCallParserTests: XCTestCase {
    let known: Set<String> = ["calculator", "zakat"]

    func testHermesFormat() {
        let r = ToolCallParser.parse("أحتاج الحساب.\n<tool_call>\n{\"name\": \"calculator\", \"arguments\": {\"expression\": \"2+2\"}}\n</tool_call>", knownTools: known)
        XCTAssertEqual(r.call?.name, "calculator")
        XCTAssertEqual(r.call?.arguments["expression"], .string("2+2"))
        XCTAssertEqual(r.text, "أحتاج الحساب.")
    }

    func testFencedAndLlamaStyle() {
        let r1 = ToolCallParser.parse("```json\n{\"name\":\"zakat\",\"parameters\":{\"cash\":5000}}\n```", knownTools: known)
        XCTAssertEqual(r1.call?.name, "zakat")
        XCTAssertEqual(r1.call?.arguments["cash"], .number(5000))
        let r2 = ToolCallParser.parse("{\"name\": \"calculator\", \"parameters\": {\"expression\": \"1+1\"}}", knownTools: known)
        XCTAssertEqual(r2.call?.name, "calculator")
    }

    func testStringifiedArguments() {
        let r = ToolCallParser.parse("<tool_call>{\"function\": {\"name\": \"calculator\", \"arguments\": \"{\\\"expression\\\": \\\"3*3\\\"}\"}}</tool_call>", knownTools: known)
        XCTAssertEqual(r.call?.arguments["expression"], .string("3*3"))
    }

    func testFinalAnswerAndThinking() {
        let r = ToolCallParser.parse("<think>المستخدم يسلّم</think>وعليكم السلام! كيف أقدر أساعدك؟", knownTools: known)
        XCTAssertNil(r.call)
        XCTAssertEqual(r.thinking, "المستخدم يسلّم")
        XCTAssertEqual(r.text, "وعليكم السلام! كيف أقدر أساعدك؟")
    }

    func testUnknownToolIsNotACall() {
        let r = ToolCallParser.parse("{\"name\": \"rm_rf\", \"arguments\": {}}", knownTools: known)
        XCTAssertNil(r.call)
    }

    func testThinkingFilter() {
        XCTAssertEqual(ThinkingFilter.strip("<think>x</think>جواب"), "جواب")
        XCTAssertEqual(ThinkingFilter.strip("قبل<think>لم ينته"), "قبل")
    }
}

/// Scripted backend for agent-loop tests.
final class ScriptedBackend: LLMBackend {
    var replies: [String]
    var received: [[ChatMessage]] = []
    init(_ r: [String]) { replies = r }
    var isReady: Bool { true }
    func generate(messages: [ChatMessage], settings: GenerationSettings, stop: [String],
                  onToken: @escaping (String) -> Bool) async throws -> (text: String, stats: GenerationStats) {
        received.append(messages)
        var r = replies.isEmpty ? "انتهى" : replies.removeFirst()
        for s in stop { if let rg = r.range(of: s) { r = String(r[..<rg.lowerBound]) } }
        _ = onToken(r)
        return (r, GenerationStats(promptTokens: 10, generatedTokens: 5, seconds: 0.1))
    }
}

final class AgentLoopTests: XCTestCase {
    func makeRegistry() -> ToolRegistry {
        let r = ToolRegistry()
        CoreTools.register(into: r, knowledge: KnowledgeBase(fileName: nil), notes: NotesStore(fileName: nil))
        return r
    }

    func testToolThenFinalAnswer() async throws {
        let backend = ScriptedBackend([
            "سأستخدم أداة الزكاة.\n<tool_call>\n{\"name\": \"zakat\", \"arguments\": {\"cash\": 120000, \"gold_price\": 410}}\n</tool_call>",
            "زكاتك 3,000 ريال.",
        ])
        let loop = AgentLoop(backend: backend, registry: makeRegistry())
        let profile = AgentProfile.builtIns.first { $0.id == "finance" }!
        let (answer, steps) = try await loop.run(goal: "كم زكاتي؟", profile: profile) { _ in }
        XCTAssertEqual(answer, "زكاتك 3,000 ريال.")
        XCTAssertEqual(steps.map(\.kind), [.thought, .toolCall, .toolResult, .final])
        XCTAssertTrue(steps[2].detail.contains("3,000.00"))
        // The tool result must be fed back to the model.
        XCTAssertTrue(backend.received[1].last!.content.contains("<tool_response>"))
        XCTAssertTrue(backend.received[0].first!.content.contains("\"name\": \"zakat\""))
    }

    func testConfirmationDenied() async throws {
        let r = makeRegistry()
        var ran = false
        r.register(ClosureTool(ToolSpec(name: "create_reminder", title: "تذكير", icon: "bell", description: "x",
                                        requiresConfirmation: true)) { _ in ran = true; return "ok" })
        let backend = ScriptedBackend([
            "<tool_call>{\"name\": \"create_reminder\", \"arguments\": {\"title\": \"اتصل\"}}</tool_call>",
            "لم أضف التذكير لأنك رفضت.",
        ])
        let loop = AgentLoop(backend: backend, registry: r, confirm: { _, _ in false })
        let profile = AgentProfile(name: "t", icon: "x", summary: "", instructions: "", toolNames: ["create_reminder"])
        let (_, steps) = try await loop.run(goal: "ذكرني", profile: profile) { _ in }
        XCTAssertFalse(ran)
        XCTAssertTrue(steps.contains { $0.kind == .denied })
    }

    func testNetworkToolHiddenWhenWebDisabled() {
        let r = makeRegistry()
        r.register(ClosureTool(ToolSpec(name: "web_search", title: "ويب", icon: "globe", description: "x", usesNetwork: true)) { _ in "" })
        let loop = AgentLoop(backend: ScriptedBackend([]), registry: r, allowNetwork: false)
        let prompt = loop.systemPrompt(for: AgentProfile.builtIns[0])
        XCTAssertFalse(prompt.contains("web_search"))
        loop.allowNetwork = true
        XCTAssertTrue(loop.systemPrompt(for: AgentProfile.builtIns[0]).contains("web_search"))
    }

    func testStepLimitForcesFinalAnswer() async throws {
        let call = "<tool_call>{\"name\": \"calculator\", \"arguments\": {\"expression\": \"1+1\"}}</tool_call>"
        let backend = ScriptedBackend([call, call, call, "النتيجة 2"])
        let loop = AgentLoop(backend: backend, registry: makeRegistry())
        var p = AgentProfile.builtIns[0]; p.maxSteps = 3
        let (answer, _) = try await loop.run(goal: "1+1", profile: p) { _ in }
        XCTAssertEqual(answer, "النتيجة 2")
    }

    func testCoreToolsProduceSaudiResults() async throws {
        let r = makeRegistry()
        let vat = try await r.tool(named: "vat")!.run(["amount": .number(100), "mode": .string("add")])
        XCTAssertTrue(vat.contains("115.00"))
        let calc = try await r.tool(named: "calculator")!.run(["expression": .string("(1250*12)*0.15")])
        XCTAssertTrue(calc.hasSuffix("= 2250"))
        let pt = try await r.tool(named: "prayer_times")!.run(["city": .string("مكة")])
        XCTAssertTrue(pt.contains("الفجر"))
    }
}

final class ServerParsingTests: XCTestCase {
    func testHTTPParse() {
        let body = "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":true,\"max_tokens\":50}"
        let raw = "POST /v1/chat/completions?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: \(body.utf8.count)\r\nAuthorization: Bearer k\r\n\r\n\(body)"
        let (req, consumed) = HTTPRequest.parse(Data(raw.utf8))!
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/v1/chat/completions")
        XCTAssertEqual(req.header("Authorization"), "Bearer k")
        XCTAssertEqual(consumed, raw.utf8.count)
        let p = ChatPayload.parse(req.body)!
        XCTAssertTrue(p.stream)
        XCTAssertEqual(p.settings.maxTokens, 50)
        XCTAssertEqual(p.messages.first?.content, "hi")
    }

    func testIncompleteBodyNeedsMore() {
        let raw = "POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n123"
        XCTAssertNil(HTTPRequest.parse(Data(raw.utf8)))
    }

    func testOllamaGenerateDefaultsToStream() {
        let p = ChatPayload.parse(Data("{\"prompt\":\"مرحبا\",\"system\":\"s\"}".utf8), ollama: true)!
        XCTAssertTrue(p.stream)
        XCTAssertEqual(p.messages.count, 2)
    }

    func testChatMLFallback() {
        let s = ChatMLFormatter.format([ChatMessage(role: .system, content: "a"), ChatMessage(role: .user, content: "b")])
        XCTAssertEqual(s, "<|im_start|>system\na<|im_end|>\n<|im_start|>user\nb<|im_end|>\n<|im_start|>assistant\n")
    }

    func testCatalogURLsAndFit() {
        for m in ModelCatalog.models {
            XCTAssertTrue(m.downloadURL.absoluteString.hasPrefix("https://huggingface.co/"))
            XCTAssertTrue(m.file.hasSuffix(".gguf"))
        }
        XCTAssertEqual(ModelCatalog.recommended(forMemory: 8 << 30).id, "qwen3-4b")
        XCTAssertEqual(ModelCatalog.recommended(forMemory: 4 << 30).id, "gemma3-1b")
        XCTAssertTrue(ModelCatalog.fits(ModelCatalog.model(id: "allam-7b")!, memory: 8 << 30))
        XCTAssertFalse(ModelCatalog.fits(ModelCatalog.model(id: "allam-7b")!, memory: 4 << 30))
    }
}
