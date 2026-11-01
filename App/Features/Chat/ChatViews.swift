import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ConversationsView: View {
    @EnvironmentObject var state: AppState
    @State private var path: [UUID] = []
    @State private var search = ""

    var filtered: [Conversation] {
        guard !search.isEmpty else { return state.conversations }
        let q = ArabicText.normalize(search)
        return state.conversations.filter {
            ArabicText.normalize($0.title).contains(q) || $0.messages.contains { ArabicText.normalize($0.content).contains(q) }
        }
    }

    struct ConvGroup: Identifiable { var id: String { title }; let title: String; let items: [Conversation] }

    var groups: [ConvGroup] {
        let cal = Calendar.current
        var today: [Conversation] = [], week: [Conversation] = [], older: [Conversation] = []
        for c in filtered {
            if cal.isDateInToday(c.updatedAt) { today.append(c) }
            else if c.updatedAt > Date().addingTimeInterval(-7 * 86400) { week.append(c) }
            else { older.append(c) }
        }
        return [ConvGroup(title: "اليوم", items: today), ConvGroup(title: "آخر ٧ أيام", items: week), ConvGroup(title: "أقدم", items: older)]
            .filter { !$0.items.isEmpty }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button(action: newChat) {
                        HStack(spacing: 12) {
                            OrbView(size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("محادثة جديدة").font(.headline)
                                Text(state.modelName(for: nil)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "square.and.pencil").font(.title3).foregroundStyle(.tint)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(groups) { g in
                    Section(g.title) {
                        ForEach(g.items) { c in
                            NavigationLink(value: c.id) { ConversationRow(c: c) }
                                .swipeActions {
                                    Button(role: .destructive) { state.deleteConversation(c.id) } label: { Label("حذف", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "ابحث في المحادثات")
            .navigationTitle("سَنَد")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: newChat) { Image(systemName: "square.and.pencil") }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ChatView(conversation: state.conversations.first { $0.id == id } ?? Conversation(id: id))
            }
            .onChange(of: state.pendingQuery) { _, _ in openPendingQuery() }
            .onAppear {
                if state.pendingQuery != nil {
                    openPendingQuery()
                } else if state.deepLinkScreen == "newChat" {
                    state.deepLinkScreen = nil
                    newChat()
                } else if UserDefaults.standard.bool(forKey: "demo"), state.tab == .chat, path.isEmpty,
                          let first = state.conversations.first(where: { $0.agentID == nil }) {
                    path = [first.id]
                }
            }
        }
    }

    func openPendingQuery() {
        guard let q = state.pendingQuery else { return }
        state.pendingQuery = nil
        let c = Conversation(personaID: state.settings.personaID)
        state.conversations.insert(c, at: 0)
        state.pendingAutoSend = q
        path = [c.id]
    }

    func newChat() {
        let c = Conversation(personaID: state.settings.personaID)
        state.conversations.insert(c, at: 0)
        path = [c.id]
    }
}

struct ConversationRow: View {
    let c: Conversation
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: c.agentID == "deep_research" ? "sparkle.magnifyingglass" : c.agentID != nil ? "wand.and.stars" : "bubble.left")
                .foregroundStyle(.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.title).font(.body.weight(.medium)).lineLimit(1)
                Text(c.messages.last?.content.replacingOccurrences(of: "\n", with: " ") ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @StateObject private var vm: ChatViewModel
    @StateObject private var speech = SpeechService.shared
    @State private var showVoice = false
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false

    init(conversation: Conversation) {
        _vm = StateObject(wrappedValue: ChatViewModel(conversation: conversation, state: AppStateHolder.shared!))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if vm.conversation.messages.isEmpty && !vm.isGenerating { emptyState }
                    ForEach(vm.conversation.messages) { m in
                        MessageRow(message: m, isLast: m.id == vm.conversation.messages.last?.id,
                                   onRegenerate: vm.regenerate, onEdit: { vm.edit(m) })
                            .id(m.id)
                    }
                    if vm.isGenerating {
                        if !vm.liveSteps.isEmpty { AgentTraceView(steps: vm.liveSteps, live: true).padding(.horizontal, 4) }
                        StreamingRow(text: vm.streaming, modelName: vm.modelName)
                    }
                    if let e = vm.error {
                        Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
                            .padding(10).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.streaming) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: vm.conversation.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .background(ChatBackground())
        .safeAreaInset(edge: .bottom) { composer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { ModelPicker(vm: vm) }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section("الشخصية") {
                        ForEach(Persona.all) { p in
                            Button { vm.setPersona(p) } label: { Label(p.name, systemImage: vm.persona.id == p.id ? "checkmark" : p.icon) }
                        }
                    }
                    Section("وكيل محدد") {
                        ForEach(state.agents) { a in
                            Button { vm.setAgent(a.id) } label: { Label(a.name, systemImage: vm.agent?.id == a.id ? "checkmark" : a.icon) }
                        }
                    }
                    Section {
                        ShareLink(item: vm.exportText) { Label("تصدير المحادثة (Markdown)", systemImage: "square.and.arrow.up") }
                        Button { vm.regenerate() } label: { Label("إعادة توليد آخر رد", systemImage: "arrow.clockwise") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .fullScreenCover(isPresented: $showVoice) { VoiceModeView(vm: vm) }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in vm.attachments.append(PendingAttachment(image: img)) }.ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in
            Task {
                for it in items {
                    if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                        vm.attachments.append(PendingAttachment(image: img))
                    }
                }
                photoItems = []
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .plainText, .text, .json, .commaSeparatedText,
                                                                     UTType(filenameExtension: "md") ?? .text, .sourceCode]) { r in
            if case .success(let url) = r {
                do { vm.attachments.append(PendingAttachment(docName: url.lastPathComponent, docText: try DocumentImporter.text(from: url))) }
                catch { vm.error = error.localizedDescription }
            }
        }
        .onAppear {
            speech.onFinal = { text in if !showVoice { vm.send(text) } }
            if let q = state.pendingAutoSend { state.pendingAutoSend = nil; vm.send(q) }
        }
    }

    // MARK: Empty state

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "صباح الخير" : "مساء الخير"
    }

    var emptyState: some View {
        VStack(spacing: 18) {
            OrbView(size: 92).padding(.top, 36)
            Text(greeting).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(vm.mode == .research ? "أبحث في الويب وأقرأ المصادر وأكتب لك تقريراً موثّقاً"
                 : vm.mode == .agent ? "أعطني مهمة وأنفّذها خطوة بخطوة بالأدوات"
                 : "كيف أقدر أساعدك اليوم؟")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(suggestions, id: \.text) { s in
                    Button { vm.setMode(s.mode); vm.send(s.text) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: s.icon).font(.title3).foregroundStyle(.tint)
                            Text(s.text).font(.footnote).multilineTextAlignment(.leading).lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    struct Suggestion { let icon: String; let text: String; let mode: ChatMode }

    var suggestions: [Suggestion] {
        [Suggestion(icon: "sparkle.magnifyingglass", text: "ابحث لي عن آخر أخبار الذكاء الاصطناعي في السعودية واكتب تقرير", mode: .research),
         Suggestion(icon: "chart.bar.xaxis", text: "احسب أقساط قرض 300 ألف على 5 سنوات بفائدة 4% واعرضها في جدول", mode: .agent),
         Suggestion(icon: "globe", text: "صمّم لي صفحة هبوط HTML لمقهى سعودي بألوان دافئة", mode: .chat),
         Suggestion(icon: "moon.stars", text: "متى صلاة المغرب في جدة اليوم وكم باقي على رمضان؟", mode: .agent)]
    }

    // MARK: Composer

    var composer: some View {
        VStack(spacing: 8) {
            if !vm.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.attachments) { a in AttachmentChip(a: a) { vm.attachments.removeAll { $0.id == a.id } } }
                    }
                    .padding(.horizontal, 4)
                }
            }
            if speech.isListening {
                Label(speech.transcript.isEmpty ? "أستمع…" : speech.transcript, systemImage: "waveform")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            VStack(spacing: 6) {
                TextField(vm.mode == .chat ? "اسأل سَنَد…" : vm.mode == .agent ? "اطلب مهمة من الوكيل…" : "عن ماذا أبحث؟",
                          text: $vm.input, axis: .vertical)
                    .lineLimit(1...8)
                    .padding(.horizontal, 6).padding(.top, 6)
                HStack(spacing: 10) {
                    Menu {
                        Button { showCamera = true } label: { Label("الكاميرا", systemImage: "camera") }
                        Button { showPhotos = true } label: { Label("الصور", systemImage: "photo.on.rectangle") }
                        Button { showFiles = true } label: { Label("ملف (PDF / نص / كود)", systemImage: "doc") }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                            .frame(width: 34, height: 34).background(Color.primary.opacity(0.06), in: Circle())
                    }
                    ForEach([ChatMode.agent, .research], id: \.self) { m in
                        Button { vm.setMode(vm.mode == m ? .chat : m) } label: {
                            Label(m.title, systemImage: m.icon).font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).frame(height: 32)
                                .background(vm.mode == m ? settings.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                                .foregroundStyle(vm.mode == m ? settings.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Button { speech.toggleListening() } label: {
                        Image(systemName: speech.isListening ? "mic.fill" : "mic").font(.system(size: 17))
                            .frame(width: 34, height: 34)
                            .symbolEffect(.pulse, isActive: speech.isListening)
                    }
                    .buttonStyle(.plain)
                    sendButton
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder var sendButton: some View {
        let empty = vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && vm.attachments.isEmpty
        if vm.isGenerating {
            Button { vm.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(.primary, in: Circle())
            }
        } else if empty {
            Button { showVoice = true } label: {
                Image(systemName: "waveform").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(settings.accentColor, in: Circle())
            }
        } else {
            Button { vm.send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(settings.accentColor, in: Circle())
            }
        }
    }
}

struct AttachmentChip: View {
    let a: PendingAttachment
    let remove: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = a.image {
                    Image(uiImage: img).resizable().scaledToFill().frame(width: 64, height: 64).clipped()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "doc.text.fill").font(.title2).foregroundStyle(.tint)
                        Text(a.docName ?? "").font(.caption2).lineLimit(1)
                    }
                    .padding(6).frame(width: 110, height: 64)
                }
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
        }
    }
}

/// Model switcher in the navigation bar (local ↔ cloud), like ChatGPT's model menu.
struct ModelPicker: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var vm: ChatViewModel

    var body: some View {
        Menu {
            Section("على الجهاز (بدون إنترنت)") {
                if models.installed.isEmpty {
                    Button { state.tab = .models } label: { Label("حمّل نموذجاً محلياً…", systemImage: "arrow.down.circle") }
                }
                ForEach(models.installed) { m in
                    Button {
                        vm.setModel("local")
                        if models.activeModelID != m.id || !state.engine.isReady {
                            Task { await models.load(m, contextLength: settings.generation.contextLength) }
                        }
                    } label: {
                        Label(m.name, systemImage: vm.modelRef == "local" && models.activeModelID == m.id ? "checkmark" : "cpu")
                    }
                }
            }
            Section("سحابي (أقوى — يحتاج إنترنت)") {
                ForEach(state.providers) { p in
                    Button { vm.setModel(p.id) } label: {
                        Label(p.displayName, systemImage: vm.modelRef == p.id ? "checkmark" : "cloud")
                    }
                }
                Button { state.tab = .more; state.deepLinkScreen = "providers" } label: {
                    Label("إضافة مزود (OpenAI، Claude، Gemini…)", systemImage: "plus")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.isCloud(vm.modelRef) ? "cloud.fill" : "cpu.fill").font(.caption)
                Text(vm.modelName).font(.subheadline.weight(.semibold)).lineLimit(1)
                if models.isLoading { ProgressView().controlSize(.mini) }
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(.primary)
        }
    }
}

struct MessageRow: View {
    @EnvironmentObject var settings: AppSettings
    let message: ChatMessage
    let isLast: Bool
    var onRegenerate: () -> Void = {}
    var onEdit: () -> Void = {}
    @State private var showSteps = false
    @State private var copied = false

    var body: some View {
        if message.role == .user { userBubble } else { assistantBlock }
    }

    var userBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let imgs = message.images, !imgs.isEmpty {
                HStack {
                    ForEach(Array(imgs.enumerated()), id: \.offset) { _, d in
                        if let ui = UIImage(data: d) {
                            Image(uiImage: ui).resizable().scaledToFill().frame(width: 90, height: 90)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
            }
            Text(displayUserText).textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(settings.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
        .contextMenu {
            Button { UIPasteboard.general.string = message.content } label: { Label("نسخ", systemImage: "doc.on.doc") }
            Button(action: onEdit) { Label("تعديل وإعادة الإرسال", systemImage: "pencil") }
        }
    }

    /// Hides long attachment text from the bubble.
    var displayUserText: String {
        guard message.content.hasPrefix("[") else { return message.content }
        return message.content.components(separatedBy: "\n\n").last ?? message.content
    }

    var assistantBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                OrbView(size: 22)
                Text(message.modelName ?? "سَنَد").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let steps = message.agentSteps, !steps.isEmpty {
                DisclosureGroup(isExpanded: $showSteps) {
                    AgentTraceView(steps: steps.filter { $0.kind != .final }, live: false).padding(.top, 8)
                } label: {
                    Label("فكّر ونفّذ \(steps.filter { $0.kind == .toolCall }.count) خطوات بالأدوات",
                          systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption.weight(.semibold))
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            MarkdownText(text: message.content)
            HStack(spacing: 18) {
                Button {
                    UIPasteboard.general.string = message.content
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                Button { SpeechService.shared.speak(message.content) } label: { Image(systemName: "speaker.wave.2") }
                ShareLink(item: message.content) { Image(systemName: "square.and.arrow.up") }
                if isLast { Button(action: onRegenerate) { Image(systemName: "arrow.clockwise") } }
                Spacer()
                if let tps = message.tokensPerSecond, tps > 0 {
                    Text(String(format: "%.1f رمز/ث", tps)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StreamingRow: View {
    let text: String
    let modelName: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                OrbView(size: 22, animating: true)
                Text(modelName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if text.isEmpty {
                TypingDots()
            } else {
                MarkdownText(text: text + " ●")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TypingDots: View {
    @State private var phase = 0.0
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().frame(width: 7, height: 7)
                        .opacity(0.3 + 0.7 * abs(sin(t * 3 + Double(i) * 0.6)))
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// Animated gradient orb — the app's visual identity.
struct OrbView: View {
    var size: CGFloat
    var animating = false
    var level: CGFloat = 0

    var body: some View {
        TimelineView(.animation(paused: !animating && level == 0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().fill(AngularGradient(colors: [Color("AccentColor"), .teal, Color("Gold"), Color("AccentColor")],
                                              center: .center, angle: .degrees(animating ? t * 60 : 30)))
                Circle().fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .topLeading,
                                             startRadius: 1, endRadius: size * 0.7))
            }
            .frame(width: size, height: size)
            .scaleEffect(1 + level * 0.25 + (animating ? 0.04 * sin(t * 2.4) : 0))
            .shadow(color: Color("AccentColor").opacity(0.35), radius: size * 0.18)
        }
        .frame(width: size * 1.3, height: size * 1.3)
    }
}

struct ChatBackground: View {
    var body: some View {
        LinearGradient(colors: [Color("AccentColor").opacity(0.06), Color(.systemBackground), Color(.systemBackground)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// Hands-free voice conversation: listen → think → speak → listen.
struct VoiceModeView: View {
    @ObservedObject var vm: ChatViewModel
    @StateObject private var speech = SpeechService.shared
    @Environment(\.dismiss) var dismiss
    @State private var spokenCount = 0

    var status: String {
        if speech.isListening { return speech.transcript.isEmpty ? "أستمع إليك…" : speech.transcript }
        if vm.isGenerating { return "أفكر…" }
        if speech.isSpeaking { return "أتحدث… (اضغط للمقاطعة)" }
        return "اضغط على الدائرة للتحدث"
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color("LaunchBackground"), .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 40) {
                HStack {
                    Text(vm.modelName).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button { speech.stopListening(); speech.stopSpeaking(); dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(.white.opacity(0.15), in: Circle())
                    }
                }
                .padding(.horizontal)
                Spacer()
                Button {
                    if speech.isSpeaking { speech.stopSpeaking(); speech.startListening() }
                    else if speech.isListening { speech.stopListening() }
                    else if !vm.isGenerating { speech.startListening() }
                } label: {
                    OrbView(size: 200, animating: speech.isListening || speech.isSpeaking || vm.isGenerating,
                            level: speech.isSpeaking ? 0.12 : speech.isListening ? 0.06 : 0)
                }
                .buttonStyle(.plain)
                Text(status).font(.title3).foregroundStyle(.white).multilineTextAlignment(.center).padding(.horizontal, 30)
                    .frame(minHeight: 80)
                if let last = vm.conversation.messages.last, last.role == .assistant {
                    Text(last.content).font(.footnote).foregroundStyle(.white.opacity(0.6)).lineLimit(4)
                        .padding(.horizontal, 30)
                }
                Spacer()
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            speech.onFinal = { text in vm.send(text) }
            spokenCount = vm.completedReplies
            speech.startListening()
        }
        .onChange(of: vm.completedReplies) { _, n in
            guard n > spokenCount, let last = vm.conversation.messages.last, last.role == .assistant else { return }
            spokenCount = n
            speech.speak(last.content)
        }
        .onChange(of: speech.isSpeaking) { was, now in
            if was && !now && !vm.isGenerating { speech.startListening() }
        }
    }
}

/// Holds a reference so views can build view models without threading the environment through init.
@MainActor
enum AppStateHolder {
    static weak var shared: AppState?
}
