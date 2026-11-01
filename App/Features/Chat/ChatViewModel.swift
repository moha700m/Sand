import Foundation
import SwiftUI
import UIKit

enum ChatMode: String, CaseIterable {
    case chat, agent, research
    var title: String {
        switch self {
        case .chat: return "محادثة"
        case .agent: return "وكيل"
        case .research: return "بحث عميق"
        }
    }
    var icon: String {
        switch self {
        case .chat: return "bubble.left"
        case .agent: return "wand.and.stars"
        case .research: return "sparkle.magnifyingglass"
        }
    }
}

struct PendingAttachment: Identifiable {
    let id = UUID()
    var image: UIImage?
    var docName: String?
    var docText: String?
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var conversation: Conversation
    @Published var input = ""
    @Published var streaming = ""
    @Published var liveSteps: [AgentStep] = []
    @Published var isGenerating = false
    @Published var error: String?
    @Published var attachments: [PendingAttachment] = []
    /// Increments every time a reply finishes (voice mode listens for this).
    @Published var completedReplies = 0

    private weak var state: AppState?
    private var task: Task<Void, Never>?

    init(conversation: Conversation, state: AppState) {
        self.conversation = conversation
        self.state = state
    }

    var modelRef: String? { conversation.modelID ?? state?.settings.defaultModelRef }

    var mode: ChatMode {
        switch conversation.agentID {
        case nil: return .chat
        case "deep_research": return .research
        default: return .agent
        }
    }

    var agent: AgentProfile? {
        guard let id = conversation.agentID else { return nil }
        return state?.agents.first { $0.id == id }
    }

    var persona: Persona { Persona.by(id: conversation.personaID) }

    var modelName: String { state?.modelName(for: modelRef) ?? "" }

    func setMode(_ m: ChatMode) {
        switch m {
        case .chat: conversation.agentID = nil
        case .agent: conversation.agentID = (agent != nil && mode == .agent) ? conversation.agentID : "sanad"
        case .research: conversation.agentID = "deep_research"
        }
        persist()
    }

    func setModel(_ ref: String) {
        conversation.modelID = ref
        state?.settings.defaultModelRef = ref
        persist()
    }

    func send(_ text: String? = nil) {
        let typed = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!typed.isEmpty || !attachments.isEmpty), !isGenerating, let state else { return }
        error = nil
        guard state.isReady(modelRef) else {
            error = state.isCloud(modelRef) ? CloudError.missingKey.localizedDescription : LLMError.noModelLoaded.localizedDescription
            return
        }
        input = ""
        let atts = attachments
        attachments = []
        let history = conversation.messages
        isGenerating = true
        streaming = ""
        liveSteps = []

        task = Task { [weak self] in
            guard let self else { return }
            let content = await self.composeContent(typed, atts, cloud: state.isCloud(self.modelRef))
            let images = atts.compactMap { $0.image?.jpegForUpload() }
            self.conversation.messages.append(ChatMessage(role: .user, content: content,
                                                          images: state.isCloud(self.modelRef) && !images.isEmpty ? images : nil))
            if self.conversation.messages.count == 1 { self.conversation.title = String((typed.isEmpty ? "صورة" : typed).prefix(48)) }
            self.persist()
            if let agent = self.agent {
                await self.runAgent(agent, goal: content, history: history, state: state)
            } else {
                await self.runChat(state: state)
            }
            self.isGenerating = false
            self.streaming = ""
            self.completedReplies += 1
            self.persist()
        }
    }

    /// Adds document text, and OCR text for images when the model can't see images.
    private func composeContent(_ typed: String, _ atts: [PendingAttachment], cloud: Bool) async -> String {
        var parts: [String] = []
        for a in atts {
            if let name = a.docName, let t = a.docText {
                parts.append("[مرفق: \(name)]\n" + String(t.prefix(12000)))
            }
            if let img = a.image, !cloud, let ocr = try? await OCRService.recognize(img), !ocr.isEmpty {
                parts.append("[نص مستخرج من صورة مرفقة]\n" + ocr)
                state?.lastImageText = ocr
            }
        }
        parts.append(typed.isEmpty ? "صف هذه الصورة واشرح محتواها." : typed)
        return parts.joined(separator: "\n\n")
    }

    private func runChat(state: AppState) async {
        let settings = ModelTuningStore.shared.tuning(for: modelRef ?? "local")
            .applied(to: state.settings.generation)
        let backend = state.backend(for: modelRef)
        let name = state.modelName(for: modelRef)
        var msgs = [ChatMessage(role: .system, content: persona.systemPrompt
                                + "\nالتاريخ: \(Hijri.describe(Date())).\nاستخدم Markdown للتنسيق، وإذا طُلب منك صفحة أو واجهة فاكتبها كملف HTML كامل داخل ```html." + state.personalContext)]
        msgs += conversation.messages.filter { $0.role != .system }
        let budget = ContextWindow.localBudget(contextLength: max(1024, settings.contextLength),
                                               maxTokens: max(256, settings.maxTokens))
        msgs = ContextWindow.fitted(msgs, budget: budget)
        var acc = ""
        var lastEmit = Date.distantPast
        do {
            let (text, stats) = try await backend.generate(messages: msgs, settings: settings, stop: []) { [weak self] piece in
                acc += piece
                let tick = Date()
                guard tick.timeIntervalSince(lastEmit) > 0.05 else { return !Task.isCancelled }
                lastEmit = tick
                let shown = settings.hideThinking ? ThinkingFilter.strip(acc) : acc
                Task { @MainActor in self?.streaming = shown }
                return !Task.isCancelled
            }
            let final = settings.hideThinking ? ThinkingFilter.strip(text) : text
            conversation.messages.append(ChatMessage(role: .assistant, content: final.isEmpty ? "…" : final,
                                                     tokensPerSecond: stats.tokensPerSecond, tokenCount: stats.generatedTokens,
                                                     modelName: name))
            if state.settings.speakReplies { SpeechService.shared.speak(final) }
        } catch {
            if !acc.isEmpty {
                conversation.messages.append(ChatMessage(role: .assistant, content: ThinkingFilter.strip(acc), modelName: name))
            }
            self.error = error is CancellationError ? nil : error.localizedDescription
        }
    }

    private func runAgent(_ agent: AgentProfile, goal: String, history: [ChatMessage], state: AppState) async {
        let loop = state.makeAgentLoop(ref: modelRef, agentID: agent.id)
        if agent.id == "deep_research" { loop.allowNetwork = true }
        var profile = agent
        profile.maxSteps = max(agent.maxSteps, state.settings.agentMaxSteps)
        let name = state.modelName(for: modelRef)
        do {
            let tuned = ModelTuningStore.shared.tuning(for: modelRef ?? "local")
                .applied(to: state.settings.generation)
            let (answer, steps) = try await loop.run(goal: goal, history: history, profile: profile, settings: tuned) { [weak self] ev in
                Task { @MainActor in
                    switch ev {
                    case .step(let s): self?.liveSteps.append(s); self?.streaming = ""
                    case .partial(let p): self?.streaming = p
                    case .finished: break
                    }
                }
            }
            conversation.messages.append(ChatMessage(role: .assistant, content: answer, agentSteps: steps, modelName: name))
            if state.settings.speakReplies { SpeechService.shared.speak(answer) }
        } catch {
            if !liveSteps.isEmpty {
                conversation.messages.append(ChatMessage(role: .assistant, content: "توقف الوكيل.", agentSteps: liveSteps, modelName: name))
            }
            self.error = error is CancellationError ? nil : error.localizedDescription
        }
        liveSteps = []
    }

    func stop() {
        task?.cancel()
        SpeechService.shared.stopSpeaking()
    }

    func regenerate() {
        guard !isGenerating, let lastUser = conversation.messages.lastIndex(where: { $0.role == .user }) else { return }
        let msg = conversation.messages[lastUser]
        conversation.messages.removeSubrange(lastUser...)
        resend(msg)
    }

    /// Puts a previous user message back in the composer and truncates the conversation from there.
    func edit(_ m: ChatMessage) {
        guard !isGenerating, let i = conversation.messages.firstIndex(where: { $0.id == m.id }) else { return }
        conversation.messages.removeSubrange(i...)
        input = m.content
        persist()
    }

    private func resend(_ msg: ChatMessage) {
        if let imgs = msg.images {
            attachments = imgs.compactMap { UIImage(data: $0) }.map { PendingAttachment(image: $0) }
        }
        send(msg.content)
    }

    func setPersona(_ p: Persona) { conversation.personaID = p.id; persist() }
    func setAgent(_ id: String?) { conversation.agentID = id; persist() }

    func persist() {
        conversation.updatedAt = Date()
        if !conversation.messages.isEmpty { state?.upsert(conversation) }
    }

    var exportText: String {
        "# \(conversation.title)\n\n" + conversation.messages.map { m in
            "**\(m.role == .user ? "أنت" : "سَنَد")**\n\n\(m.content)"
        }.joined(separator: "\n\n---\n\n")
    }
}

extension UIImage {
    /// Downscales to at most 1280px and encodes JPEG for upload.
    func jpegForUpload(maxSide: CGFloat = 1280) -> Data? {
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let img = UIGraphicsImageRenderer(size: target).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
        return img.jpegData(compressionQuality: 0.8)
    }
}
