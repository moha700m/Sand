import Foundation

/// Cheap, dependency-free token estimation and context fitting.
/// The estimate is intentionally conservative: it is used to avoid overflows, not for billing.
public enum ContextWindow {
    /// Arabic script costs roughly 2 characters per token on most tokenizers; Latin ~4.
    public static func estimateTokens(_ text: String) -> Int {
        var arabic = 0, other = 0
        for scalar in text.unicodeScalars {
            if (0x0600...0x06FF).contains(scalar.value) || (0x0750...0x077F).contains(scalar.value) { arabic += 1 }
            else { other += 1 }
        }
        return max(1, arabic / 2 + other / 4)
    }

    public static func messageTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1.content) + 4 }
    }

    /// Keeps the system message plus the most recent turns that fit the budget.
    /// Older turns are dropped whole; the system message is always preserved.
    public static func fitted(_ messages: [ChatMessage], budget: Int, keepSystem: Bool = true) -> [ChatMessage] {
        guard budget > 0 else { return keepSystem ? messages.filter { $0.role == .system } : [] }
        var system: [ChatMessage] = []
        var rest: [ChatMessage] = []
        for m in messages {
            if m.role == .system && keepSystem { system.append(m) } else { rest.append(m) }
        }
        var used = messageTokens(system)
        var kept: [ChatMessage] = []
        for m in rest.reversed() {
            let cost = estimateTokens(m.content) + 4
            if used + cost > budget { break }
            used += cost
            kept.insert(m, at: 0)
        }
        // Always keep at least the last user message so the request is valid.
        if kept.isEmpty, let last = rest.last { kept = [last] }
        return system + kept
    }

    /// Returns a short note describing what was dropped, for the model's awareness.
    public static func omissionNote(_ original: [ChatMessage], fitted: [ChatMessage]) -> String? {
        let dropped = max(0, original.count - fitted.count)
        guard dropped > 0 else { return nil }
        return "\n\n[ملاحظة نظام: تم إسقاط \(dropped) رسالة أقدم لتجاوز حد السياق.]"
    }

    /// Budget for a local model given its context size and requested completion length.
    public static func localBudget(contextLength: Int, maxTokens: Int, reserve: Int = 64) -> Int {
        max(512, contextLength - min(maxTokens, contextLength / 2) - reserve)
    }
}
