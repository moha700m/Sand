import XCTest

final class ChatArchiveTests: XCTestCase {

    func testParsesIOSArabicExportWithBidiMarks() {
        let raw = """
        \u{200E}[١٢‏/١٠‏/٢٠٢٦، ٨:١٥:٢٣ م] ‏محمد: السلام عليكم
        \u{200E}[١٢‏/١٠‏/٢٠٢٦، ٨:١٦:٠٠ م] ‏سارة: وعليكم السلام
        \u{200E}[١٢‏/١٠‏/٢٠٢٦، ٨:١٧:٠٠ م] ‏محمد: نجتمع الخميس الساعة ٩
        """
        let archive = ChatArchiveParser.parse(raw)
        XCTAssertEqual(archive.messageCount, 3)
        XCTAssertEqual(archive.participantCount, 2)
        XCTAssertEqual(archive.participants["محمد"], 2)
        XCTAssertEqual(archive.messages.first?.text, "السلام عليكم")
        XCTAssertNotNil(archive.firstDate)
        XCTAssertNotNil(archive.lastDate)
    }

    func testParsesAndroidExport() {
        let raw = """
        12/10/2026, 20:15 - محمد: مرحبا
        12/10/2026, 20:16 - سارة: أهلاً
        """
        let archive = ChatArchiveParser.parse(raw)
        XCTAssertEqual(archive.messageCount, 2)
        XCTAssertEqual(archive.messages[1].sender, "سارة")
        XCTAssertEqual(archive.messages[1].text, "أهلاً")
    }

    func testMultilineMessageIsJoined() {
        let raw = """
        [12/10/2026, 20:15:00] محمد: سطر أول
        سطر ثاني
        [12/10/2026, 20:16:00] سارة: رد
        """
        let archive = ChatArchiveParser.parse(raw)
        XCTAssertEqual(archive.messageCount, 2)
        XCTAssertEqual(archive.messages[0].text, "سطر أول\nسطر ثاني")
    }

    func testSystemLinesAreSkipped() {
        let raw = """
        [12/10/2026, 20:14:00] تم تشفير هذه الرسالة
        [12/10/2026, 20:15:00] محمد: نص
        """
        let archive = ChatArchiveParser.parse(raw)
        XCTAssertEqual(archive.messageCount, 1)
    }

    func testMediaPlaceholdersAreMarked() {
        let raw = """
        [12/10/2026, 20:15:00] محمد: <Media omitted>
        [12/10/2026, 20:16:00] سارة: نص عادي
        """
        let archive = ChatArchiveParser.parse(raw)
        XCTAssertTrue(archive.messages[0].isMedia)
        XCTAssertFalse(archive.messages[1].isMedia)
    }

    func testChunkingSplitsLongChats() {
        var messages: [ArchiveMessage] = []
        for i in 0..<20 {
            messages.append(ArchiveMessage(sender: "محمد", text: "رسالة رقم \(i) " + String(repeating: "ط", count: 60)))
        }
        let chunks = ChatArchiveParser.chunks(messages, maxCharacters: 500)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty })
    }

    func testLooksLikeExport() {
        let raw = """
        [12/10/2026, 20:15:00] محمد: مرحبا
        [12/10/2026, 20:16:00] سارة: أهلاً
        [12/10/2026, 20:17:00] محمد: كيف الحال
        """
        XCTAssertTrue(ChatArchiveParser.looksLikeExport(raw))
        XCTAssertFalse(ChatArchiveParser.looksLikeExport("مجرد نص عادي بدون رسائل"))
    }
}
