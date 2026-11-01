import Foundation

public struct ToolCall: Equatable, Sendable {
    public var name: String
    public var arguments: ToolArguments
    public init(name: String, arguments: ToolArguments) { self.name = name; self.arguments = arguments }
}

public struct ParsedAgentReply: Equatable, Sendable {
    /// Free text before the tool call (the model's reasoning) or the final answer when `call` is nil.
    public var text: String
    public var thinking: String?
    public var call: ToolCall?
}

/// Extracts a tool call from model output. Accepts:
/// - Hermes/Qwen style `<tool_call>{"name":…, "arguments":{…}}</tool_call>`
/// - fenced ```json blocks containing `name`/`tool` and `arguments`/`parameters`
/// - Llama 3.x style bare JSON `{"name": …, "parameters": {…}}`
public enum ToolCallParser {
    public static func parse(_ raw: String, knownTools: Set<String>) -> ParsedAgentReply {
        var text = raw
        var thinking: String?
        if let open = text.range(of: "<think>") {
            let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex)
            let end = close?.lowerBound ?? text.endIndex
            thinking = String(text[open.upperBound..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            text.removeSubrange(open.lowerBound..<(close?.upperBound ?? text.endIndex))
        }

        // 1) <tool_call> … </tool_call>
        if let open = text.range(of: "<tool_call>") {
            let close = text.range(of: "</tool_call>", range: open.upperBound..<text.endIndex)
            let body = String(text[open.upperBound..<(close?.lowerBound ?? text.endIndex)])
            if let call = decodeCall(body, knownTools: knownTools) {
                let before = String(text[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                return ParsedAgentReply(text: before, thinking: thinking, call: call)
            }
        }
        // 2) fenced json
        if let fence = text.range(of: "```json") ?? text.range(of: "```") {
            let rest = text[fence.upperBound...]
            if let end = rest.range(of: "```") {
                let body = String(rest[..<end.lowerBound])
                if let call = decodeCall(body, knownTools: knownTools) {
                    let before = String(text[..<fence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return ParsedAgentReply(text: before, thinking: thinking, call: call)
                }
            }
        }
        // 3) first balanced JSON object anywhere
        if let (json, range) = firstJSONObject(in: text), let call = decodeCall(json, knownTools: knownTools) {
            let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedAgentReply(text: before, thinking: thinking, call: call)
        }
        let final = text.replacingOccurrences(of: "</tool_call>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedAgentReply(text: final, thinking: thinking, call: nil)
    }

    static func decodeCall(_ body: String, knownTools: Set<String>) -> ToolCall? {
        guard let (json, _) = firstJSONObject(in: body),
              let data = json.data(using: .utf8),
              let obj = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
        // OpenAI-ish nesting {"function": {"name":…, "arguments": "…"}}
        if case .object(let fn)? = obj["function"] {
            return decodeFlat(fn, knownTools: knownTools)
        }
        return decodeFlat(obj, knownTools: knownTools)
    }

    private static func decodeFlat(_ obj: [String: JSONValue], knownTools: Set<String>) -> ToolCall? {
        guard let name = (obj["name"] ?? obj["tool"] ?? obj["tool_name"])?.stringValue,
              knownTools.isEmpty || knownTools.contains(name) else { return nil }
        var args: ToolArguments = [:]
        switch obj["arguments"] ?? obj["parameters"] ?? obj["args"] ?? obj["input"] {
        case .object(let o)?: args = o
        case .string(let s)?:
            if let d = s.data(using: .utf8), let o = try? JSONDecoder().decode(ToolArguments.self, from: d) { args = o }
        default: break
        }
        return ToolCall(name: name, arguments: args)
    }

    /// Finds the first balanced `{…}` (string-aware).
    static func firstJSONObject(in s: String) -> (String, Range<String.Index>)? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        let r = start..<s.index(after: i)
                        return (String(s[r]), r)
                    }
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
