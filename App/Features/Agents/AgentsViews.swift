import SwiftUI

struct AgentsView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: AgentProfile?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("وكلاء يفكرون وينفّذون", systemImage: "wand.and.stars").font(.headline)
                        Text("الوكيل يقسّم مهمتك لخطوات، ويستخدم الأدوات (حاسبة، تقويم، مستنداتك، مواقيت الصلاة…) ويعرض لك كل خطوة. أي إجراء يغيّر شيئاً على جهازك يحتاج موافقتك.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Section("الوكلاء") {
                    ForEach(state.agents) { a in
                        NavigationLink(value: a) {
                            HStack(spacing: 12) {
                                Image(systemName: a.icon).font(.title3).frame(width: 36, height: 36)
                                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name).font(.headline)
                                    Text(a.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Text("\(a.toolNames.contains("*") ? "كل الأدوات" : "\(a.toolNames.count) أداة") · حتى \(a.maxSteps) خطوات").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .swipeActions {
                            if !a.builtIn {
                                Button(role: .destructive) { state.deleteAgent(a.id) } label: { Label("حذف", systemImage: "trash") }
                            }
                            Button { editing = a } label: { Label("تعديل", systemImage: "pencil") }.tint(.blue)
                        }
                    }
                }
                Section("الأدوات المتاحة") {
                    ForEach(state.registry.specs) { t in
                        HStack {
                            Image(systemName: t.icon).frame(width: 24).foregroundStyle(.tint)
                            Text(t.title)
                            Spacer()
                            if t.requiresConfirmation { Image(systemName: "hand.raised").font(.caption).foregroundStyle(.orange) }
                            if t.usesNetwork {
                                Image(systemName: "globe").font(.caption).foregroundStyle(state.settings.webAccess ? .blue : .gray)
                            }
                        }
                    }
                }
            }
            .navigationTitle("الوكلاء")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = AgentProfile(name: "وكيل جديد", icon: "person.crop.circle.badge.questionmark", summary: "",
                                               instructions: "أنت وكيل مساعد. استخدم الأدوات عند الحاجة.", toolNames: ["calculator", "current_datetime"])
                    } label: { Image(systemName: "plus") }
                }
            }
            .navigationDestination(for: AgentProfile.self) { a in AgentRunView(agent: a) }
            .sheet(item: $editing) { a in AgentEditor(agent: a) }
            .onAppear {
                if state.deepLinkScreen == "agentRun", let a = state.agents.first(where: { $0.id == "finance" }) {
                    state.deepLinkScreen = nil
                    path.append(a)
                }
            }
        }
    }
}

/// Dedicated task runner showing the live plan → tool → result trace.
struct AgentRunView: View {
    @EnvironmentObject var state: AppState
    let agent: AgentProfile
    @State private var goal = ""
    @State private var steps: [AgentStep] = []
    @State private var partial = ""
    @State private var answer = ""
    @State private var running = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ModelStatusBanner()
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(agent.name, systemImage: agent.icon).font(.headline)
                        Text(agent.summary).font(.footnote).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(state.registry.specs(for: agent.toolNames, allowNetwork: true).map(\.name), id: \.self) { n in
                                    if let t = state.registry.tool(named: n)?.spec {
                                        Label(t.title, systemImage: t.icon).font(.caption2)
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                                    }
                                }
                            }
                        }
                    }
                }
                TextField("وش المهمة؟", text: $goal, axis: .vertical)
                    .lineLimit(2...6)
                    .padding(12)
                    .background(Color("CardBackground"), in: RoundedRectangle(cornerRadius: 14))
                HStack {
                    if running {
                        Button(role: .destructive) { task?.cancel() } label: { Label("إيقاف", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    } else {
                        Button(action: run) { Label("نفّذ المهمة", systemImage: "play.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                            .disabled(goal.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .controlSize(.large)

                if !steps.isEmpty { AgentTraceView(steps: steps.filter { $0.kind != .final }, live: running) }
                if running && !partial.isEmpty {
                    Text(partial).font(.callout).foregroundStyle(.secondary)
                }
                if !answer.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("النتيجة", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
                            MarkdownText(text: answer)
                            HStack {
                                ShareLink(item: answer) { Label("مشاركة", systemImage: "square.and.arrow.up") }
                                Spacer()
                                Button { SpeechService.shared.speak(answer) } label: { Label("استمع", systemImage: "speaker.wave.2") }
                            }
                            .font(.footnote)
                        }
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            .padding()
        }
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if UserDefaults.standard.bool(forKey: "demo"), steps.isEmpty { DemoContent.fillAgentRun(goal: &goal, steps: &steps, answer: &answer) }
        }
    }

    func run() {
        guard state.engineReady else { error = LLMError.noModelLoaded.localizedDescription; return }
        error = nil; steps = []; answer = ""; partial = ""; running = true
        let loop = state.makeAgentLoop(agentID: agent.id)
        if agent.id == "deep_research" { loop.allowNetwork = true }
        var profile = agent
        profile.maxSteps = max(agent.maxSteps, state.settings.agentMaxSteps)
        let g = goal
        task = Task {
            do {
                let result = try await loop.run(goal: g, profile: profile) { ev in
                    Task { @MainActor in
                        switch ev {
                        case .step(let s): steps.append(s); partial = ""
                        case .partial(let p): partial = p
                        case .finished(let a): answer = a
                        }
                    }
                }
                answer = result.answer
                var c = Conversation(title: String(g.prefix(40)), agentID: agent.id)
                c.messages = [ChatMessage(role: .user, content: g),
                              ChatMessage(role: .assistant, content: result.answer, agentSteps: result.steps)]
                state.upsert(c)
            } catch is CancellationError {
                error = "تم الإيقاف."
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}

struct AgentTraceView: View {
    let steps: [AgentStep]
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                StepRow(step: s, isLast: i == steps.count - 1 && !live)
            }
            if live {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("يعمل…").font(.caption).foregroundStyle(.secondary) }
                    .padding(.leading, 4).padding(.top, 6)
            }
        }
    }

    struct StepRow: View {
        let step: AgentStep
        let isLast: Bool
        @State private var expanded = false

        var color: Color {
            switch step.kind {
            case .thought: return .gray
            case .toolCall: return .indigo
            case .toolResult: return .green
            case .denied: return .orange
            case .error: return .red
            case .final: return .accentColor
            }
        }

        var icon: String {
            switch step.kind {
            case .thought: return "brain"
            case .toolCall: return "wrench.and.screwdriver.fill"
            case .toolResult: return "checkmark.circle.fill"
            case .denied: return "hand.raised.fill"
            case .error: return "xmark.octagon.fill"
            case .final: return "flag.checkered"
            }
        }

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    Image(systemName: icon).font(.caption).foregroundStyle(.white)
                        .frame(width: 24, height: 24).background(color, in: Circle())
                    if !isLast { Rectangle().fill(color.opacity(0.3)).frame(width: 2).frame(maxHeight: .infinity) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title).font(.subheadline.weight(.semibold))
                    Text(step.detail)
                        .font(step.kind == .toolCall ? .caption.monospaced() : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 3)
                        .onTapGesture { withAnimation { expanded.toggle() } }
                }
                .padding(.bottom, 12)
                Spacer(minLength: 0)
            }
        }
    }
}

struct AgentEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State var agent: AgentProfile

    var body: some View {
        NavigationStack {
            Form {
                Section("الأساسيات") {
                    TextField("الاسم", text: $agent.name)
                    TextField("وصف مختصر", text: $agent.summary)
                    Picker("الأيقونة", selection: $agent.icon) {
                        ForEach(["wand.and.stars", "brain.head.profile", "briefcase", "book", "cart", "car", "stethoscope",
                                 "building.2", "graduationcap", "person.crop.circle.badge.questionmark", "leaf", "airplane"], id: \.self) {
                            Image(systemName: $0).tag($0)
                        }
                    }
                    Stepper("أقصى عدد خطوات: \(agent.maxSteps)", value: $agent.maxSteps, in: 1...12)
                }
                Section("التعليمات") {
                    TextEditor(text: $agent.instructions).frame(minHeight: 120)
                }
                Section("الأدوات") {
                    ForEach(state.registry.specs) { t in
                        Toggle(isOn: Binding(
                            get: { agent.toolNames.contains(t.name) },
                            set: { on in
                                if on { agent.toolNames.append(t.name) } else { agent.toolNames.removeAll { $0 == t.name } }
                            })) {
                            Label(t.title, systemImage: t.icon)
                        }
                    }
                }
                if agent.builtIn {
                    Section { Text("التعديل على وكيل جاهز يُحفظ كنسخة خاصة بك.").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(agent.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        var a = agent
                        if a.builtIn { a.id = UUID().uuidString; a.builtIn = false; a.name += " (نسختي)" }
                        state.saveAgent(a)
                        dismiss()
                    }
                }
            }
        }
    }
}
