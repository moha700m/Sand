import XCTest

final class Sanad3Tests: XCTestCase {

    // MARK: Workspace

    func makeStore() -> (WorkspaceStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        let store = WorkspaceStore(root: root, maxFileBytes: 4096, maxTotalBytes: 64 * 1024)
        return (store, root)
    }

    func testPathTraversalRejected() {
        let (store, _) = makeStore()
        XCTAssertThrowsError(try store.url("agent", "../secret.txt"))
        XCTAssertThrowsError(try store.url("agent", "a/../../secret.txt"))
        XCTAssertThrowsError(try store.url("agent", "/etc/passwd"))
        XCTAssertThrowsError(try store.url("agent", "~/file"))
    }

    func testWriteReadRoundTrip() throws {
        let (store, _) = makeStore()
        _ = try store.write("agent", "src/main.swift", text: "print(\"hi\")")
        XCTAssertEqual(try store.readText("agent", "src/main.swift"), "print(\"hi\")")
        XCTAssertTrue(store.exists("agent", "src/main.swift"))
    }

    func testListAndDelete() throws {
        let (store, _) = makeStore()
        _ = try store.write("agent", "a.txt", text: "1")
        _ = try store.write("agent", "b.txt", text: "2")
        let nodes = try store.list("agent")
        XCTAssertEqual(nodes.count, 2)
        try store.delete("agent", "a.txt")
        XCTAssertEqual(try store.list("agent").count, 1)
    }

    func testRename() throws {
        let (store, _) = makeStore()
        _ = try store.write("agent", "old.md", text: "x")
        _ = try store.rename("agent", "old.md", to: "new.md")
        XCTAssertFalse(store.exists("agent", "old.md"))
        XCTAssertTrue(store.exists("agent", "new.md"))
    }

    func testOversizeRejected() {
        let (store, _) = makeStore()
        let big = String(repeating: "ا", count: 5000)
        XCTAssertThrowsError(try store.write("agent", "big.txt", text: big))
    }

    func testSearchFindsContent() throws {
        let (store, _) = makeStore()
        _ = try store.write("agent", "notes.md", text: "الرياض عاصمة المملكة")
        let hits = try store.search("agent", query: "الرياض")
        XCTAssertFalse(hits.isEmpty)
    }

    // MARK: ZIP

    func testZipRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).zip")
        let entries = [("a.txt", Data("hello".utf8)), ("dir/b.txt", Data("world".utf8))]
        try ZipWriter.write(entries: entries, to: url)
        let read = try ZipReader.read(url)
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read.first { $0.path == "a.txt" }?.data, Data("hello".utf8))
        XCTAssertEqual(read.first { $0.path == "dir/b.txt" }?.data, Data("world".utf8))
        try? FileManager.default.removeItem(at: url)
    }

    func testZipEmptyRejected() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("e-\(UUID().uuidString).zip")
        XCTAssertThrowsError(try ZipWriter.write(entries: [], to: url))
    }

    // MARK: Skills

    func testSkillFrontMatterParsed() {
        let md = """
        ---
        name: مراجعة كود
        description: مراجعة صارمة
        category: programming
        tools: [workspace_read, run_javascript]
        ---

        # مراجعة
        اقرأ الملف أولاً.
        """
        let skill = SkillParser.parse(md, fallbackName: "x")
        XCTAssertEqual(skill?.name, "مراجعة كود")
        XCTAssertEqual(skill?.category, .programming)
        XCTAssertEqual(skill?.tools.count, 2)
        XCTAssertTrue(skill?.body.contains("اقرأ الملف") ?? false)
    }

    func testSkillWithoutFrontMatterUsesHeading() {
        let md = "# مهارة بسيطة\n\nافعل الشيء."
        let skill = SkillParser.parse(md)
        XCTAssertEqual(skill?.name, "مهارة بسيطة")
    }

    func testBuiltInSkillsCount() {
        XCTAssertGreaterThanOrEqual(BuiltInSkills.all.count, 9)
    }

    func testSkillRenderRoundTrip() {
        let original = SkillPackage(id: "x", name: "اختبار", summary: "وصف", category: .data, body: "# محتوى")
        let rendered = SkillParser.render(original)
        let parsed = SkillParser.parse(rendered)
        XCTAssertEqual(parsed?.name, "اختبار")
        XCTAssertEqual(parsed?.category, .data)
    }

    // MARK: User tools

    func testToolNameValidation() {
        var t = UserTool(name: "Bad Name", title: "t", summary: "s", kind: .javascript, code: "return 1")
        XCTAssertThrowsError(try ToolValidator.validate(t))
        t.name = "good_name"
        XCTAssertNoThrow(try ToolValidator.validate(t))
    }

    func testHTTPSchemeValidation() {
        let insecure = UserTool(name: "fetch_it", title: "t", summary: "s", kind: .http, url: "http://example.com/x")
        XCTAssertThrowsError(try ToolValidator.validate(insecure))
        let local = UserTool(name: "fetch_it", title: "t", summary: "s", kind: .http, url: "http://192.168.1.10:1234/x")
        XCTAssertNoThrow(try ToolValidator.validate(local))
        let secure = UserTool(name: "fetch_it", title: "t", summary: "s", kind: .http, url: "https://api.example.com/x")
        XCTAssertNoThrow(try ToolValidator.validate(secure))
    }

    func testTemplateSubstitution() {
        let out = UserToolRuntime.substitute("https://x/{{input.id}}?q={{input.q}}",
                                             ["id": .string("42"), "q": .string("سَنَد")])
        XCTAssertEqual(out, "https://x/42?q=سَنَد")
    }

    // MARK: Agent packages

    func testAgentPackageCodable() throws {
        let pkg = AgentPackage(name: "وكيل", summary: "s", instructions: "i", tools: ["*"], maxSteps: 7)
        let data = try JSONEncoder().encode(pkg)
        let back = try JSONDecoder().decode(AgentPackage.self, from: data)
        XCTAssertEqual(back.name, "وكيل")
        XCTAssertEqual(back.maxSteps, 7)
        XCTAssertEqual(back.schemaVersion, AgentPackage.currentSchema)
    }

    func testAgentPackageMarkdown() {
        let pkg = AgentPackage(name: "مهندس", instructions: "اكتب كوداً")
        let md = pkg.markdown()
        XCTAssertTrue(md.contains("# مهندس"))
        XCTAssertTrue(md.contains("اكتب كوداً"))
    }

    // MARK: Context / permissions

    func testContextWindowKeepsSystemAndTail() {
        var msgs: [ChatMessage] = [ChatMessage(role: .system, content: "system")]
        for i in 0..<40 { msgs.append(ChatMessage(role: .user, content: String(repeating: "ك", count: 400) + "\(i)")) }
        let fitted = ContextWindow.fitted(msgs, budget: 600)
        XCTAssertEqual(fitted.first?.role, .system)
        XCTAssertLessThan(fitted.count, msgs.count)
        XCTAssertEqual(fitted.last?.content.last, "9")
    }

    func testPermissionClassification() {
        let write = ToolSpec(name: "workspace_write", title: "w", icon: "x", description: "")
        XCTAssertEqual(PermissionManager.permission(for: write), .writeLocal)
        let net = ToolSpec(name: "web_search", title: "s", icon: "x", description: "", usesNetwork: true)
        XCTAssertEqual(PermissionManager.permission(for: net), .network)
        let read = ToolSpec(name: "workspace_read", title: "r", icon: "x", description: "")
        XCTAssertEqual(PermissionManager.permission(for: read), .readLocal)
    }

    func testPolicyDeniesNetwork() {
        let spec = ToolSpec(name: "web_search", title: "s", icon: "x", description: "", usesNetwork: true)
        XCTAssertNotNil(PermissionManager.denialReason(spec, policy: .local))
        XCTAssertNil(PermissionManager.denialReason(spec, policy: .research))
    }

    func testAllowedPrefixes() {
        let policy = PermissionPolicy(allowedPrefixes: ["workspace_*"])
        XCTAssertTrue(policy.allows(tool: "workspace_write"))
        XCTAssertFalse(policy.allows(tool: "web_search"))
    }
}

// MARK: - 3.1 Arena / Eval / Tuning

final class ArenaTests: XCTestCase {
    func testEloExpectedAtEqualRatings() {
        XCTAssertEqual(Elo.expected(1200, 1200), 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(Elo.expected(1400, 1200), 0.5)
        XCTAssertLessThan(Elo.expected(1000, 1200), 0.5)
    }

    func testEloWinnerGainsPoints() {
        let (a, b) = Elo.update(a: 1200, b: 1200, scoreA: 1)
        XCTAssertGreaterThan(a, 1200)
        XCTAssertLessThan(b, 1200)
        XCTAssertEqual(a + b, 2400, accuracy: 0.0001)
    }

    func testEloTieKeepsEqualRatings() {
        let (a, b) = Elo.update(a: 1200, b: 1200, scoreA: 0.5)
        XCTAssertEqual(a, 1200, accuracy: 0.0001)
        XCTAssertEqual(b, 1200, accuracy: 0.0001)
    }

    func testArenaRecordUpdatesLeaderboard() {
        let store = ArenaStore(fileName: nil)
        let match = ArenaMatch(prompt: "س", refA: "local", refB: "cloud",
                               nameA: "محلي", nameB: "سحابي", answerA: "أ", answerB: "ب",
                               secondsA: 1, secondsB: 2, blind: true)
        store.record(match, winner: .a)
        let board = store.leaderboard
        XCTAssertEqual(board.count, 2)
        XCTAssertEqual(board.first?.name, "محلي")
        XCTAssertEqual(board.first?.rating.wins, 1)
    }

    func testTuningOverridesOnlySpecifiedFields() {
        var base = GenerationSettings()
        base.temperature = 0.7
        base.maxTokens = 512
        let tuned = ModelTuning(temperature: 0.1).applied(to: base)
        XCTAssertEqual(tuned.temperature, 0.1)
        XCTAssertEqual(tuned.maxTokens, 512)
    }

    func testEvalCaseChecksAreDeterministic() {
        guard let json = QualityEval.cases.first(where: { $0.id == "json" }) else { return XCTFail("missing case") }
        XCTAssertTrue(json.check("{\"name\": \"سَنَد\"}"))
        XCTAssertFalse(json.check("لا يوجد JSON هنا"))

        guard let math = QualityEval.cases.first(where: { $0.id == "math" }) else { return XCTFail("missing case") }
        XCTAssertTrue(math.check("391"))
        XCTAssertFalse(math.check("390"))

        guard let arabic = QualityEval.cases.first(where: { $0.id == "arabic" }) else { return XCTFail("missing case") }
        XCTAssertTrue(arabic.check("الرياض مدينة جميلة ومتنامية"))
        XCTAssertFalse(arabic.check("Riyadh"))
    }
}
