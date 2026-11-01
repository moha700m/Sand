import Combine
import Foundation

/// Turns a chat export into a structured brief using the active model.
/// Chunk → summarize → merge, so small local context windows still work.
@MainActor
final class ChatBriefing: ObservableObject {
    enum BriefingError: LocalizedError {
        case empty
        case noModel

        var errorDescription: String? {
            switch self {
            case .empty: return "لا توجد رسائل كافية في الملف."
            case .noModel: return "حمّل نموذجاً محلياً أو اضبط مزوداً سحابياً أولاً."
            }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = ""
    @Published private(set) var brief = ""

    static let maxMessages = 400
    static let maxChunks = 12

    func run(messages: [ArchiveMessage], backend: LLMBackend) async throws -> String {
        guard messages.count >= 3 else { throw BriefingError.empty }
        isRunning = true
        brief = ""
        progress = 0
        status = "أقرأ المحادثة…"
        defer { isRunning = false }

        let trimmed = Array(messages.suffix(Self.maxMessages))
        var chunks = ChatArchiveParser.chunks(trimmed)
        if chunks.count > Self.maxChunks {
            // Keep coverage of the whole chat by merging the tail chunks.
            chunks = Array(chunks.suffix(Self.maxChunks))
        }
        guard !chunks.isEmpty else { throw BriefingError.empty }

        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            status = chunks.count == 1 ? "ألخّص المحادثة…" : "أقرأ المقطع \(index + 1) من \(chunks.count)…"
            progress = Double(index) / Double(chunks.count + 1)
            let note = try await ask(system: Self.chunkPrompt, user: chunk, backend: backend, maxTokens: 380)
            notes.append(note)
        }

        try Task.checkCancellation()
        status = "أجمع الزبدة…"
        progress = Double(chunks.count) / Double(chunks.count + 1)
        let merged = try await ask(system: Self.mergePrompt,
                                   user: notes.joined(separator: "\n\n---\n\n"),
                                   backend: backend,
                                   maxTokens: 900)
        brief = cleaned(merged)
        progress = 1
        status = "تم"
        return brief
    }

    func reset() {
        brief = ""
        progress = 0
        status = ""
    }

    // MARK: Model

    private func ask(system: String, user: String, backend: LLMBackend, maxTokens: Int) async throws -> String {
        var settings = GenerationSettings.agent
        settings.temperature = 0.25
        settings.maxTokens = maxTokens
        settings.enableThinking = false

        let messages = [
            ChatMessage(role: .system, content: system),
            ChatMessage(role: .user, content: user),
        ]
        let (text, _) = try await backend.generate(messages: messages, settings: settings, stop: []) { _ in true }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleaned(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("```") {
            out = out.replacingOccurrences(of: "```markdown", with: "")
                .replacingOccurrences(of: "```md", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    // MARK: Prompts

    static let chunkPrompt = """
    أنت محلل محادثات دقيق. اقرأ مقتطف محادثة واتساب التالي واستخرج بالعربية، بنقاط قصيرة جداً:
    - موضوع النقاش
    - قرارات أو اتفاقات
    - مهام أو التزامات: من؟ ماذا؟ ومتى إن ذُكر
    - مواعيد أو أرقام أو عناوين مهمة
    - نقطة معلّقة أو خلاف
    لا تخترع أي معلومة. تجاهل السلام والرسائل القصيرة بلا معنى والوسائط. إذا لم تجد شيئاً اكتب «لا شيء».
    """

    static let mergePrompt = """
    لديك ملخصات عدة مقاطع من محادثة واحدة. اجمعها في خلاصة نهائية بالعربية بصيغة ماركداون بهذه الأقسام بالضبط:

    ## الزبدة
    - من ٣ إلى ٥ نقاط تشرح ما دار في المحادثة.

    ## القرارات
    - كل قرار أو اتفاق واضح.

    ## المهام
    - [ ] المهمة — المسؤول — الموعد إن وجد

    ## مواعيد وأرقام
    - التواريخ والمبالغ والأرقام والعناوين المهمة.

    ## معلّق
    - ما لم يُحسم بعد.

    احذف التكرار. لا تخترع. إذا لم يوجد ما يخص قسماً فاكتب تحته «لا شيء».
    """
}
