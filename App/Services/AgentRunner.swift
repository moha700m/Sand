import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Runs agent tasks independently of any screen.
///
/// A run started here keeps going when the user leaves the screen, switches tabs,
/// or sends the app to the background (within the time iOS grants). Jobs are
/// persisted, so a relaunch still shows what happened instead of losing the trace.
/// One job executes at a time; the rest wait in the queue.
@MainActor
final class AgentRunner: ObservableObject {
    enum JobState: String, Codable {
        case queued, running, done, failed, cancelled, interrupted

        var title: String {
            switch self {
            case .queued: return "في الانتظار"
            case .running: return "قيد التنفيذ"
            case .done: return "اكتملت"
            case .failed: return "فشلت"
            case .cancelled: return "أُوقفت"
            case .interrupted: return "انقطعت"
            }
        }

        var isActive: Bool { self == .queued || self == .running }

        var icon: String {
            switch self {
            case .queued: return "clock"
            case .running: return "bolt.fill"
            case .done: return "checkmark.seal.fill"
            case .failed: return "exclamationmark.triangle.fill"
            case .cancelled: return "stop.circle"
            case .interrupted: return "pause.circle"
            }
        }
    }

    struct Job: Identifiable, Codable, Equatable {
        var id = UUID()
        var agentID: String
        var agentName: String
        var agentIcon: String
        var goal: String
        var steps: [AgentStep] = []
        var partial = ""
        var answer = ""
        var state: JobState = .queued
        var error: String?
        var queuedAt = Date()
        var startedAt = Date()
        var endedAt: Date?

        var isActive: Bool { state.isActive }
        var elapsed: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

        var toolCallCount: Int { steps.filter { $0.kind == .toolCall }.count }
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var lastFinishedID: UUID?

    private static let file = "agent-jobs.json"
    private static let maxJobs = 30

    private weak var owner: AppState?
    private var task: Task<Void, Never>?
    private var currentID: UUID?
    private var bgToken: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []

    init() {
        if let saved = Storage.load([Job].self, from: Self.file) {
            jobs = saved.map { job in
                var copy = job
                if copy.state.isActive {
                    copy.state = .interrupted
                    copy.endedAt = copy.endedAt ?? Date()
                }
                return copy
            }.sorted { $0.queuedAt > $1.queuedAt }
        }
        observeLifecycle()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Wiring

    func attach(_ state: AppState) { owner = state }

    var activeJobs: [Job] { jobs.filter(\.isActive) }
    var finishedJobs: [Job] { jobs.filter { !$0.isActive } }
    var hasActiveJob: Bool { currentID != nil || !activeJobs.isEmpty }

    func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    func activeJob(for agentID: String) -> Job? {
        jobs.first { $0.agentID == agentID && $0.isActive }
    }

    func lastJob(for agentID: String) -> Job? {
        jobs.first { $0.agentID == agentID }
    }

    // MARK: Queue

    @discardableResult
    func start(goal: String, agent: AgentProfile) -> UUID {
        var job = Job(agentID: agent.id, agentName: agent.name, agentIcon: agent.icon,
                      goal: goal.trimmingCharacters(in: .whitespacesAndNewlines))
        job.queuedAt = Date()
        job.startedAt = Date()
        jobs.insert(job, at: 0)
        trim()
        persist()
        pump()
        return job.id
    }

    @discardableResult
    func retry(_ id: UUID) -> UUID? {
        guard let old = job(id), !old.state.isActive else { return nil }
        let profile = AgentProfile(id: old.agentID, name: old.agentName, icon: old.agentIcon,
                                   summary: "", instructions: "", toolNames: ["*"], maxSteps: 8)
        return start(goal: old.goal, agent: profile)
    }

    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].state == .queued {
            jobs[i].state = .cancelled
            jobs[i].endedAt = Date()
            persist()
            return
        }
        guard currentID == id else { return }
        jobs[i].state = .cancelled
        persist()
        task?.cancel()
    }

    func remove(_ id: UUID) {
        guard let job = job(id), !job.state.isActive else { return }
        jobs.removeAll { $0.id == id }
        persist()
    }

    func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
        persist()
    }

    // MARK: Execution

    private func pump() {
        guard task == nil, currentID == nil else { return }
        guard let owner else { return }
        guard let index = jobs.lastIndex(where: { $0.state == .queued }) else { return }

        let job = jobs[index]
        let pkg = owner.packages.first { $0.id == job.agentID }
        var profile = pkg?.profile() ?? AgentProfile(id: job.agentID, name: job.agentName, icon: job.agentIcon,
                                                     summary: "وكيل محذوف",
                                                     instructions: "أنت وكيل مساعد دقيق. استخدم الأدوات عند الحاجة ثم أجب بالعربية.",
                                                     toolNames: ["*"], maxSteps: 8)
        profile.maxSteps = max(profile.maxSteps, owner.settings.agentMaxSteps)

        let loop = owner.makeAgentLoop(ref: pkg?.modelRef, agentID: job.agentID)
        if pkg?.allowNetwork == true { loop.allowNetwork = true }
        var settings = GenerationSettings.agent
        if let pkg {
            settings.temperature = pkg.temperature
            settings.maxTokens = max(256, pkg.maxTokens)
        }

        jobs[index].state = .running
        jobs[index].startedAt = Date()
        currentID = job.id
        setIdleTimer(true)
        persist()

        task = Task { [weak self] in
            do {
                let result = try await loop.run(goal: job.goal, profile: profile, settings: settings) { event in
                    Task { @MainActor [weak self] in self?.apply(event, to: job.id) }
                }
                self?.finish(job.id, answer: result.answer, steps: result.steps, error: nil, cancelled: false)
            } catch is CancellationError {
                self?.finish(job.id, answer: "", steps: [], error: nil, cancelled: true)
            } catch {
                self?.finish(job.id, answer: "", steps: [], error: error.localizedDescription, cancelled: false)
            }
        }
    }

    private func apply(_ event: AgentEvent, to id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .running else { return }
        switch event {
        case .step(let step):
            if jobs[i].steps.last?.id != step.id { jobs[i].steps.append(step) }
            if step.kind == .toolCall { jobs[i].partial = "" }
        case .partial(let text):
            jobs[i].partial = String(text.suffix(1600))
        case .finished(let answer):
            jobs[i].answer = answer
        }
        if jobs[i].steps.count % 4 == 0 { persist() }
    }

    private func finish(_ id: UUID, answer: String, steps: [AgentStep], error: String?, cancelled: Bool) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if !steps.isEmpty { jobs[i].steps = steps }
        jobs[i].endedAt = Date()
        jobs[i].partial = ""
        if cancelled {
            jobs[i].state = .cancelled
        } else if let error {
            jobs[i].state = .failed
            jobs[i].error = error
        } else {
            jobs[i].state = .done
            jobs[i].answer = answer
        }
        lastFinishedID = jobs[i].id

        if !cancelled, error == nil, let owner, !answer.isEmpty {
            let goal = jobs[i].goal
            var conversation = Conversation(title: String(goal.prefix(40)), agentID: jobs[i].agentID)
            conversation.messages = [
                ChatMessage(role: .user, content: goal),
                ChatMessage(role: .assistant, content: answer, agentSteps: jobs[i].steps,
                            modelName: owner.modelName(for: owner.package(for: jobs[i].agentID)?.modelRef)),
            ]
            owner.upsert(conversation)
        }

        task = nil
        currentID = nil
        setIdleTimer(false)
        if !hasActiveJob { endBackgroundTask() }
        persist()
        pump()
    }

    // MARK: Persistence

    private func persist() {
        trim()
        Storage.save(jobs, to: Self.file)
    }

    private func trim() {
        while jobs.count > Self.maxJobs {
            guard let index = jobs.lastIndex(where: { !$0.isActive }) else { break }
            jobs.remove(at: index)
        }
    }

    // MARK: Background execution

    private func observeLifecycle() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.backgroundEntered() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.foregroundEntered() }
        })
        #endif
    }

    private func backgroundEntered() {
        guard hasActiveJob else { return }
        beginBackgroundTask()
    }

    private func foregroundEntered() {
        endBackgroundTask()
        if currentID != nil, task == nil, let id = currentID,
           let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].state = .interrupted
            jobs[i].endedAt = Date()
            currentID = nil
            setIdleTimer(false)
            persist()
            pump()
        }
    }

    private func beginBackgroundTask() {
        #if canImport(UIKit)
        guard bgToken == .invalid else { return }
        bgToken = UIApplication.shared.beginBackgroundTask(withName: "sanad.agent.run") { [weak self] in
            Task { @MainActor in
                // iOS is about to suspend us. Keep the trace on disk and let the
                // run resume when the app comes back.
                self?.persist()
                self?.endBackgroundTask()
            }
        }
        #endif
    }

    private func endBackgroundTask() {
        #if canImport(UIKit)
        guard bgToken != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgToken)
        bgToken = .invalid
        #endif
    }

    private func setIdleTimer(_ on: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}
