import Foundation

/// Minimal JSON value used for tool arguments.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var compactJSON: String {
        guard let d = try? JSONEncoder().encode(self), let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }
}

public typealias ToolArguments = [String: JSONValue]

public extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? { self[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
    func decimal(_ key: String) -> Decimal? { string(key).flatMap { Decimal(arabic: $0) } }
}

public struct ToolParameter: Codable, Equatable, Sendable {
    public var name: String
    public var type: String
    public var description: String
    public var required: Bool
    public init(_ name: String, _ type: String = "string", _ description: String, required: Bool = true) {
        self.name = name; self.type = type; self.description = description; self.required = required
    }
}

public struct ToolSpec: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var title: String
    public var icon: String
    public var description: String
    public var parameters: [ToolParameter]
    /// Tools that change something outside the conversation require explicit user approval.
    public var requiresConfirmation: Bool
    /// Tools that reach the network are only offered when web access is enabled.
    public var usesNetwork: Bool

    public init(name: String, title: String, icon: String, description: String,
                parameters: [ToolParameter] = [], requiresConfirmation: Bool = false, usesNetwork: Bool = false) {
        self.name = name; self.title = title; self.icon = icon; self.description = description
        self.parameters = parameters; self.requiresConfirmation = requiresConfirmation; self.usesNetwork = usesNetwork
    }

    /// JSON-schema-ish description injected into the system prompt.
    public var promptDescription: String {
        let params = parameters.map { p in
            "\"\(p.name)\": {\"type\": \"\(p.type)\", \"description\": \"\(p.description)\"\(p.required ? ", \"required\": true" : "")}"
        }.joined(separator: ", ")
        return "{\"name\": \"\(name)\", \"description\": \"\(description)\", \"parameters\": {\(params)}}"
    }
}

public protocol AgentTool: AnyObject {
    var spec: ToolSpec { get }
    func run(_ args: ToolArguments) async throws -> String
}

public struct ToolError: LocalizedError {
    public var message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// A tool backed by a closure — convenient for simple tools.
public final class ClosureTool: AgentTool {
    public let spec: ToolSpec
    private let body: (ToolArguments) async throws -> String
    public init(_ spec: ToolSpec, _ body: @escaping (ToolArguments) async throws -> String) {
        self.spec = spec
        self.body = body
    }
    public func run(_ args: ToolArguments) async throws -> String { try await body(args) }
}

public final class ToolRegistry {
    public private(set) var tools: [String: AgentTool] = [:]
    public var order: [String] = []

    public init() {}

    public func register(_ tool: AgentTool) {
        if tools[tool.spec.name] == nil { order.append(tool.spec.name) }
        tools[tool.spec.name] = tool
    }

    public func tool(named n: String) -> AgentTool? { tools[n] }

    public var specs: [ToolSpec] { order.compactMap { tools[$0]?.spec } }

    public func specs(for names: [String], allowNetwork: Bool) -> [ToolSpec] {
        var resolved: [String] = []
        for n in names {
            if n == "*" { resolved += order }
            else if n.hasSuffix("*") { resolved += order.filter { $0.hasPrefix(String(n.dropLast())) } }
            else { resolved.append(n) }
        }
        var seen = Set<String>()
        return resolved.filter { seen.insert($0).inserted }
            .compactMap { tools[$0]?.spec }.filter { allowNetwork || !$0.usesNetwork }
    }

    public func unregister(name: String) {
        tools[name] = nil
        order.removeAll { $0 == name }
    }

    public func unregister(prefix: String) {
        for n in order where n.hasPrefix(prefix) { tools[n] = nil }
        order.removeAll { $0.hasPrefix(prefix) }
    }
}
