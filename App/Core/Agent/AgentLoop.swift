import Foundation

public struct AgentStep: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case thought, toolCall, toolResult, denied, error, final }
    public var id: UUID = UUID()
    public var kind: Kind
    public var title: String
    public var detail: String
    public var toolName: String?
    public var date: Date = Date()

    public init(kind: Kind, title: String, detail: String, toolName: String? = nil) {
        self.kind = kind; self.title = title; self.detail = detail; self.toolName = toolName
    }
}

public struct AgentProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var icon: String
    public var summary: String
    public var instructions: String
    public var toolNames: [String]
    public var maxSteps: Int
    public var builtIn: Bool

    public init(id: String = UUID().uuidString, name: String, icon: String, summary: String,
                instructions: String, toolNames: [String], maxSteps: Int = 6, builtIn: Bool = false) {
        self.id = id; self.name = name; self.icon = icon; self.summary = summary
        self.instructions = instructions; self.toolNames = toolNames; self.maxSteps = maxSteps; self.builtIn = builtIn
    }

    public static let allCoreTools: [String] = ["*"]
    public static let legacyCoreTools = [
        "calculator", "current_datetime", "hijri_date", "prayer_times", "qibla", "zakat", "vat",
        "end_of_service", "knowledge_search", "read_document", "notes_add", "notes_search",
        "create_reminder", "create_event", "image_text", "web_search",
    ]

    public static let builtIns: [AgentProfile] = AgentPackageStore.builtIns.map { $0.profile() }
}

/// Hard ceilings for one agent run. All four are enforced, not advisory.
public struct AgentLimits: Codable, Equatable, Sendable {
    public var maxSteps: Int
    public var maxToolCalls: Int
    public var maxSeconds: Double
    public var maxIdenticalCalls: Int

    public init(maxSteps: Int = 8, maxToolCalls: Int = 16, maxSeconds: Double = 240, maxIdenticalCalls: Int = 2) {
        self.maxSteps = maxSteps; self.maxToolCalls = maxToolCalls
        self.maxSeconds = maxSeconds; self.maxIdenticalCalls = maxIdenticalCalls
    }
}

public enum AgentStopReason: String, Sendable {
    case completed, stepLimit, toolCallLimit, timeLimit, repeatedCalls, cancelled, failed
}

public enum AgentEvent {
    case step(AgentStep)
    case partial(String)
    case finished(String)
}

/// Bounded ReAct loop: plan → call one tool → observe → repeat until an answer or a limit.
public final class AgentLoop {
    public let backend: LLMBackend
    public let registry: ToolRegistry
    public var allowNetwork: Bool
    public var confirm: (ToolSpec, ToolArguments) async -> Bool
    public var now: () -> Date
    public var extraContext: String = ""
    public var skillsBlock: String = ""
    public var policy = PermissionPolicy.local
    public var limits = AgentLimits()
    public private(set) var lastStopReason: AgentStopReason = .completed

    public init(backend: LLMBackend, registry: ToolRegistry, allowNetwork: Bool = false,
                confirm: @escaping (ToolSpec, ToolArguments) async -> Bool = { _, _ in false },
                now: @escaping () -> Date = Date.init) {
        self.backend = backend
        self.registry = registry
        self.allowNetwork = allowNetwork
        self.confirm = confirm
        self.now = now
    }

    public func systemPrompt(for profile: AgentProfile) -> String {
        let specs = registry.specs(for: profile.toolNames, allowNetwork: allowNetwork).filter { policy.allows(tool: $0.name) }
        let tools = specs.map(\.promptDescription).joined(separator: "\n")
        return """
        \(profile.instructions)

        التاريخ الحالي: \(Hijri.describe(now())).\(extraContext)\(skillsBlock)

        # الأدوات
        لديك الأدوات التالية:
        <tools>
        \(tools)
        </tools>

        # طريقة العمل
        - فكّر بإيجاز فيما تحتاجه.
        - لاستخدام أداة، اكتب سطراً واحداً بالضبط بهذا الشكل ثم توقف:
        <tool_call>
        {"name": "اسم_الأداة", "arguments": {"المعامل": "القيمة"}}
        </tool_call>
        - تصلك النتيجة داخل <tool_response>. يمكنك استدعاء أداة أخرى إذا احتجت.
        - لا تكرر نفس الاستدعاء بنفس المعاملات؛ إن فشل فغيّر المدخلات أو غيّر الأسلوب.
        - عندما تكتمل المعلومات اكتب الإجابة النهائية مباشرة بدون أي <tool_call>.
        - لا تخترع نتائج الأدوات أبداً. وإن لم تجد معلومة، قل ذلك صراحة.
        """
    }

    public func run(goal: String, history: [ChatMessage] = [], profile: AgentProfile,
                    settings: GenerationSettings = .agent,
                    onEvent: @escaping (AgentEvent) -> Void) async throws -> (answer: String, steps: [AgentStep]) {
        var steps: [AgentStep] = []
        func emit(_ s: AgentStep) { steps.append(s); onEvent(.step(s)) }

        let started = now()
        let deadline = started.addingTimeInterval(max(5, limits.maxSeconds))
        let stepCap = max(1, min(profile.maxSteps, limits.maxSteps > 0 ? limits.maxSteps : profile.maxSteps))
        let callCap = max(1, limits.maxToolCalls)
        var toolCalls = 0
        var signatureCounts: [String: Int] = [:]
        var consecutiveErrors = 0

        var messages: [ChatMessage] = [ChatMessage(role: .system, content: systemPrompt(for: profile))]
        messages += history.filter { $0.role == .user || $0.role == .assistant }.suffix(6)
        messages.append(ChatMessage(role: .user, content: goal))

        let known = Set(registry.specs(for: profile.toolNames, allowNetwork: allowNetwork)
            .map(\.name).filter { policy.allows(tool: $0) })
        let budget = ContextWindow.localBudget(contextLength: max(1024, settings.contextLength),
                                               maxTokens: max(256, settings.maxTokens))

        func callModel(stop: [String], streaming: Bool) async throws -> String {
            let fitted = ContextWindow.fitted(messages, budget: budget)
            var streamed = ""
            let (raw, _) = try await backend.generate(messages: fitted, settings: settings, stop: stop) { piece in
                streamed += piece
                if streaming, !streamed.contains("<tool_call>") {
                    onEvent(.partial(ThinkingFilter.strip(streamed)))
                }
                return !Task.isCancelled
            }
            return raw
        }

        for stepIndex in 0..<stepCap {
            try Task.checkCancellation()
            if now() > deadline {
                lastStopReason = .timeLimit
                emit(AgentStep(kind: .error, title: "انتهى الوقت", detail: "تجاوز التنفيذ \(Int(limits.maxSeconds)) ثانية."))
                break
            }

            let raw = try await callModel(stop: ["</tool_call>", "<tool_response>"], streaming: true)
            let completed = raw.contains("<tool_call>") && !raw.contains("</tool_call>") ? raw + "</tool_call>" : raw
            let parsed = ToolCallParser.parse(completed, knownTools: known)

            if let t = parsed.thinking, !t.isEmpty, stepIndex == 0 {
                emit(AgentStep(kind: .thought, title: "تفكير", detail: String(t.prefix(600))))
            }

            guard let call = parsed.call else {
                var answer = parsed.text.isEmpty ? ThinkingFilter.strip(raw) : parsed.text
                if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messages.append(ChatMessage(role: .user, content: "اكتب الآن إجابتك النهائية للمستخدم بالعربية، بدون أدوات."))
                    let retry = try await callModel(stop: ["<tool_call>"], streaming: true)
                    answer = ThinkingFilter.strip(retry)
                }
                lastStopReason = .completed
                let final = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "لم أتمكن من إنتاج إجابة." : answer
                emit(AgentStep(kind: .final, title: "الإجابة", detail: final))
                onEvent(.finished(final))
                return (final, steps)
            }

            if !parsed.text.isEmpty {
                emit(AgentStep(kind: .thought, title: "خطة", detail: String(parsed.text.prefix(800))))
            }
            let argsJSON = JSONValue.object(call.arguments).compactJSON
            guard let tool = registry.tool(named: call.name), known.contains(call.name) else {
                emit(AgentStep(kind: .error, title: "أداة غير متاحة", detail: call.name))
                messages.append(ChatMessage(role: .assistant, content: completed))
                messages.append(ChatMessage(role: .user, content: "<tool_response>\nخطأ: الأداة \(call.name) غير متاحة. المتاح: \(known.sorted().joined(separator: ", "))\n</tool_response>"))
                consecutiveErrors += 1
                if consecutiveErrors >= 3 { lastStopReason = .failed; break }
                continue
            }

            let signature = call.name + argsJSON
            let seen = signatureCounts[signature, default: 0]
            if seen >= max(1, limits.maxIdenticalCalls) {
                lastStopReason = .repeatedCalls
                emit(AgentStep(kind: .error, title: "تكرار غير مفيد",
                               detail: "تكرر الاستدعاء \(seen) مرات بنفس المعاملات. أوقفت التنفيذ.", toolName: call.name))
                messages.append(ChatMessage(role: .user, content: "<tool_response>\nتوقفت: كررت نفس الاستدعاء. اكتب الإجابة النهائية بما لديك الآن.\n</tool_response>"))
                break
            }
            signatureCounts[signature] = seen + 1
            toolCalls += 1

            emit(AgentStep(kind: .toolCall, title: tool.spec.title, detail: argsJSON, toolName: call.name))

            var result: String
            if let denial = PermissionManager.denialReason(tool.spec, policy: policy) {
                result = "ممنوع: \(denial)"
                emit(AgentStep(kind: .denied, title: "صلاحية مرفوضة", detail: denial, toolName: call.name))
            } else if PermissionManager.requiresConfirmation(tool.spec) {
                if await confirm(tool.spec, call.arguments) {
                    result = await execute(tool, call.arguments, emit: emit)
                } else {
                    result = "رفض المستخدم تنفيذ هذه الأداة. لا تحاول مرة أخرى، وأخبره بما كنت ستفعله."
                    emit(AgentStep(kind: .denied, title: "رفض المستخدم", detail: tool.spec.title, toolName: call.name))
                }
            } else {
                result = await execute(tool, call.arguments, emit: emit)
            }

            if result.hasPrefix("خطأ:") { consecutiveErrors += 1 } else { consecutiveErrors = 0 }
            if result.count > 4000 { result = String(result.prefix(4000)) + "\n…(مقتطع)" }

            messages.append(ChatMessage(role: .assistant,
                                        content: "<tool_call>\n{\"name\": \"\(call.name)\", \"arguments\": \(argsJSON)}\n</tool_call>"))
            messages.append(ChatMessage(role: .user, content: "<tool_response>\n\(result)\n</tool_response>"))

            if toolCalls >= callCap {
                lastStopReason = .toolCallLimit
                emit(AgentStep(kind: .error, title: "حد الأدوات", detail: "تم استدعاء \(toolCalls) أداة — الحد الأقصى."))
                break
            }
            if consecutiveErrors >= 3 {
                lastStopReason = .failed
                emit(AgentStep(kind: .error, title: "توقف", detail: "ثلاثة أخطاء متتالية في الأدوات."))
                break
            }
            if stepIndex == stepCap - 1 { lastStopReason = .stepLimit }
        }

        // Always try to produce a user-facing answer, even after hitting a limit.
        if lastStopReason == .completed { lastStopReason = .stepLimit }
        messages.append(ChatMessage(role: .user, content: "انتهى تنفيذ الأدوات. اكتب الآن أفضل إجابة نهائية ممكنة بناءً على ما سبق، بدون أدوات."))
        var acc = ""
        let (raw, _) = try await backend.generate(
            messages: ContextWindow.fitted(messages, budget: budget),
            settings: settings, stop: ["<tool_call>"]) { piece in
                acc += piece
                onEvent(.partial(ThinkingFilter.strip(acc))); return !Task.isCancelled
            }
        let answer = ThinkingFilter.strip(raw)
        emit(AgentStep(kind: .final, title: "الإجابة", detail: answer))
        onEvent(.finished(answer))
        return (answer, steps)
    }

    private func execute(_ tool: AgentTool, _ args: ToolArguments,
                         emit: (AgentStep) -> Void) async -> String {
        do {
            let out = try await tool.run(args)
            emit(AgentStep(kind: .toolResult, title: "نتيجة \(tool.spec.title)", detail: String(out.prefix(1200)), toolName: tool.spec.name))
            return out
        } catch {
            let message = "خطأ: \(error.localizedDescription)"
            emit(AgentStep(kind: .error, title: "فشل \(tool.spec.title)", detail: error.localizedDescription, toolName: tool.spec.name))
            return message
        }
    }
}
