import Foundation

/// Deterministic, on-device quality checks. No judge model, no network.
public struct EvalCase: Sendable {
    public var id: String
    public var title: String
    public var prompt: String
    public var maxTokens: Int
    public var check: @Sendable (String) -> Bool

    public init(id: String, title: String, prompt: String, maxTokens: Int,
                check: @escaping @Sendable (String) -> Bool) {
        self.id = id; self.title = title; self.prompt = prompt
        self.maxTokens = maxTokens; self.check = check
    }
}

public struct EvalResult: Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var passed: Bool
    public var output: String
}

public struct EvalReport: Sendable {
    public var modelName: String
    public var results: [EvalResult]
    public var score: Double { results.isEmpty ? 0 : Double(results.filter(\.passed).count) / Double(results.count) }
    public var passed: Int { results.filter(\.passed).count }
}

public enum QualityEval {
    public static let cases: [EvalCase] = [
        EvalCase(id: "json", title: "إخراج JSON صحيح",
                 prompt: "أعد كائن JSON فقط يحتوي مفتاح name وقيمته \"سَنَد\". لا تكتب أي شرح خارج JSON.",
                 maxTokens: 120) { out in
            guard let start = out.firstIndex(of: "{"), let end = out.lastIndex(of: "}") else { return false }
            let slice = String(out[start...end])
            guard let data = slice.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return (obj["name"] as? String)?.contains("سَنَد") == true
        },
        EvalCase(id: "math", title: "حساب دقيق",
                 prompt: "ما ناتج 17 × 23؟ اكتب الرقم فقط بدون أي كلمات.",
                 maxTokens: 32) { out in
            out.filter(\.isNumber).contains("391")
        },
        EvalCase(id: "follow", title: "اتباع تعليمات صارمة",
                 prompt: "اكتب الكلمة التالية فقط: تم",
                 maxTokens: 16) { out in
            out.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) == "تم"
        },
        EvalCase(id: "format", title: "تنسيق قائمة",
                 prompt: "اكتب ثلاث نقاط فقط، كل نقطة في سطر تبدأ بـ - . لا مقدمات ولا خاتمة.",
                 maxTokens: 100) { out in
            let lines = out.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            return lines.filter { $0.hasPrefix("-") && $0.count > 2 }.count >= 3
        },
        EvalCase(id: "code", title: "كتابة دالة",
                 prompt: "اكتب دالة JavaScript باسم add تأخذ رقمين وتعيد مجموعهما. الكود فقط.",
                 maxTokens: 160) { out in
            let low = out.lowercased()
            return (low.contains("function add") || low.contains("const add") || low.contains("add ="))
                && low.contains("return")
        },
        EvalCase(id: "arabic", title: "عربية سليمة",
                 prompt: "اكتب جملة عربية واحدة قصيرة عن الرياض.",
                 maxTokens: 80) { out in
            let arabic = out.unicodeScalars.filter { (0x0600...0x06FF).contains($0.value) }.count
            return arabic >= 12
        },
    ]

    /// Runs every case against the backend. Cases are independent, so one failure never aborts the run.
    public static func evaluate(backend: LLMBackend, modelName: String,
                                base: GenerationSettings) async -> EvalReport {
        var results: [EvalResult] = []
        for c in cases {
            var s = base
            s.maxTokens = c.maxTokens
            s.temperature = 0.1
            let output: String
            do {
                output = try await backend.generate(messages: [ChatMessage(role: .user, content: c.prompt)],
                                                    settings: s, stop: []) { _ in true }.text
            } catch {
                output = "خطأ: \(error.localizedDescription)"
            }
            results.append(EvalResult(name: c.title, passed: c.check(output),
                                      output: String(output.prefix(400))))
        }
        return EvalReport(modelName: modelName, results: results)
    }
}

public struct SpeedReport: Sendable {
    public var modelName: String
    public var tokens: Int
    public var seconds: Double
    public var tokensPerSecond: Double
    public var promptTokens: Int
}

public enum SpeedBenchmark {
    static let prompt = "اكتب فقرة عربية موجزة عن أهمية الماء في حياة الإنسان، واذكر ثلاث فوائد له."

    public static func run(backend: LLMBackend, modelName: String,
                           base: GenerationSettings, tokens: Int = 64) async throws -> SpeedReport {
        var s = base
        s.maxTokens = max(16, tokens)
        s.temperature = 0.2
        let start = Date()
        let (text, _) = try await backend.generate(messages: [ChatMessage(role: .user, content: prompt)],
                                                   settings: s, stop: []) { _ in true }
        let seconds = Date().timeIntervalSince(start)
        let generated = max(1, ContextWindow.estimateTokens(text))
        return SpeedReport(modelName: modelName, tokens: generated, seconds: seconds,
                           tokensPerSecond: Double(generated) / max(seconds, 0.001),
                           promptTokens: ContextWindow.estimateTokens(prompt))
    }
}
