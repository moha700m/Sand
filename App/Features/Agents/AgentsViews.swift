import SwiftUI

/// Task runner for one agent. The run itself lives in `AgentRunner`, so leaving
/// this screen — or the whole app — does not stop it.
struct AgentRunView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var runner: AgentRunner
    let agent: AgentProfile

    @State private var goal = ""
    @State private var jobID: UUID?
    @State private var message: String?
    @FocusState private var editingGoal: Bool

    var job: AgentRunner.Job? { jobID.flatMap { runner.job($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ModelStatusBanner()
                if let job {
                    live(job)
                } else {
                    compose
                }
            }
            .padding()
            .padding(.bottom, 24)
        }
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: attachRunningJob)
    }

    // MARK: Compose

    var compose: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label(agent.name, systemImage: agent.icon).font(.headline)
                    if !agent.summary.isEmpty {
                        Text(agent.summary).font(.footnote).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            chip("\(agent.toolNames.contains("*") ? "كل الأدوات" : "\(agent.toolNames.count) أداة")")
                            chip("حتى \(agent.maxSteps) خطوة")
                        }
                    }
                }
            }

            TextField("اكتب المهمة… مثال: احسب زكاتي واحفظ النتيجة في مساحة العمل", text: $goal, axis: .vertical)
                .lineLimit(3...8)
                .focused($editingGoal)
                .padding(12)
                .background(Color("CardBackground"), in: RoundedRectangle(cornerRadius: 14))

            Button(action: run) {
                Label("نفّذ المهمة", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Label("بعد التشغيل تكمل المهمة في الخلفية حتى لو رجعت للرئيسية أو قفلت الشاشة.",
                  systemImage: "moon.zzz.fill")
                .font(.caption).foregroundStyle(.secondary)

            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
    }

    // MARK: Live job

    func live(_ job: AgentRunner.Job) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AgentJobStatusCard(job: job)

            if !job.steps.isEmpty {
                AgentTraceView(steps: job.steps.filter { $0.kind != .final }, live: job.isActive)
            }

            if job.isActive && !job.partial.isEmpty {
                Text(job.partial).font(.callout).foregroundStyle(.secondary)
            }

            if !job.answer.isEmpty {
                AgentAnswerCard(text: job.answer)
            }

            if let error = job.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                if job.isActive {
                    Button(role: .destructive) { runner.cancel(job.id) } label: {
                        Label("إيقاف", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        if let newID = runner.retry(job.id) { jobID = newID }
                    } label: {
                        Label("إعادة", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        jobID = nil
                        goal = ""
                        message = nil
                    } label: {
                        Label("مهمة جديدة", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
    }

    // MARK: Actions

    func attachRunningJob() {
        guard jobID == nil else { return }
        if let running = runner.activeJob(for: agent.id) ?? runner.lastJob(for: agent.id), running.isActive {
            jobID = running.id
        }
    }

    func run() {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let ref = state.package(for: agent.id)?.modelRef
        guard state.isReady(ref) else {
            message = state.isCloud(ref)
                ? "مفتاح المزود السحابي غير مضبوط. افتح «مزودو السحابة» وأضف المفتاح."
                : "حمّل نموذجاً محلياً أولاً من تبويب النماذج."
            return
        }
        message = nil
        editingGoal = false
        jobID = runner.start(goal: text, agent: agent)
    }

    func chip(_ text: String) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
    }
}

/// Read-only live view of any job, opened from the run list.
struct AgentJobDetailView: View {
    @EnvironmentObject var runner: AgentRunner
    let jobID: UUID

    var body: some View {
        ScrollView {
            if let job = runner.job(jobID) {
                VStack(alignment: .leading, spacing: 14) {
                    AgentJobStatusCard(job: job)
                    if !job.steps.isEmpty {
                        AgentTraceView(steps: job.steps.filter { $0.kind != .final }, live: job.isActive)
                    }
                    if job.isActive && !job.partial.isEmpty {
                        Text(job.partial).font(.callout).foregroundStyle(.secondary)
                    }
                    if !job.answer.isEmpty { AgentAnswerCard(text: job.answer) }
                    if let error = job.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    HStack(spacing: 10) {
                        if job.isActive {
                            Button(role: .destructive) { runner.cancel(job.id) } label: {
                                Label("إيقاف", systemImage: "stop.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button { runner.retry(job.id) } label: {
                                Label("إعادة التشغيل", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .controlSize(.large)
                }
                .padding()
            } else {
                ContentUnavailableView("المهمة غير موجودة", systemImage: "tray",
                                       description: Text("ربما حُذفت من السجل."))
            }
        }
        .navigationTitle(runner.job(jobID)?.agentName ?? "مهمة")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AgentJobStatusCard: View {
    let job: AgentRunner.Job

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: job.agentIcon)
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.agentName).font(.headline)
                        Text(job.goal).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Spacer()
                }

                HStack(spacing: 12) {
                    Label(job.state.title, systemImage: job.state.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                    if job.state == .running {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text("\(job.steps.count) خطوة · \(job.toolCallCount) أداة")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }

                if job.isActive {
                    Label("تعمل في الخلفية — يمكنك الخروج من الشاشة", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    var color: Color {
        switch job.state {
        case .done: return .green
        case .failed: return .red
        case .cancelled, .interrupted: return .orange
        case .queued: return .secondary
        case .running: return .accentColor
        }
    }
}

struct AgentAnswerCard: View {
    let text: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("النتيجة", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(.green)
                MarkdownText(text: text)
                HStack {
                    ShareLink(item: text) { Label("مشاركة", systemImage: "square.and.arrow.up") }
                    Spacer()
                    Button { SpeechService.shared.speak(text) } label: {
                        Label("استمع", systemImage: "speaker.wave.2")
                    }
                }
                .font(.footnote)
            }
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
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("يعمل…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 4).padding(.top, 6)
            }
        }
    }

    struct StepRow: View {
        let step: AgentStep
        let isLast: Bool
        @State private var expanded = false

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(color)
                        .frame(width: 24, height: 24)
                        .background(color.opacity(0.12), in: Circle())
                    if !isLast {
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1.5)
                            .frame(maxHeight: .infinity)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title).font(.subheadline.weight(.medium))
                    if !step.detail.isEmpty {
                        Text(step.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 3)
                            .textSelection(.enabled)
                    }
                }
                .padding(.bottom, 10)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        }

        var icon: String {
            switch step.kind {
            case .thought: return "brain"
            case .toolCall: return "hammer.fill"
            case .toolResult: return "checkmark"
            case .denied: return "hand.raised.fill"
            case .error: return "exclamationmark.triangle.fill"
            case .final: return "flag.checkered"
            }
        }

        var color: Color {
            switch step.kind {
            case .thought: return .purple
            case .toolCall: return .blue
            case .toolResult: return .green
            case .denied: return .orange
            case .error: return .red
            case .final: return .accentColor
            }
        }
    }
}
