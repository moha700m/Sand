import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

public enum UserToolKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case javascript, http, workflow
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .javascript: return "JavaScript"
        case .http: return "HTTP"
        case .workflow: return "سلسلة أدوات"
        }
    }
    public var icon: String {
        switch self {
        case .javascript: return "curlybraces"
        case .http: return "network"
        case .workflow: return "point.3.connected.trianglepath.dotted"
        }
    }
}

public struct ToolStep: Codable, Hashable, Sendable {
    public var tool: String
    /// Values may reference `{{input.key}}` or `{{step1}}` (output of an earlier step).
    public var arguments: [String: String]
    public init(tool: String, arguments: [String: String] = [:]) {
        self.tool = tool; self.arguments = arguments
    }
}

/// A tool the user (or an agent) authored. Executed through a sandboxed runtime.
public struct UserTool: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String          // tool name exposed to the agent: lowercase_with_underscores
    public var title: String
    public var summary: String
    public var kind: UserToolKind
    public var code: String
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var bodyTemplate: String
    public var params: [ToolParameter]
    public var steps: [ToolStep]
    public var requiresConfirmation: Bool
    public var enabled: Bool
    public var version: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, title: String, summary: String,
                kind: UserToolKind, code: String = "", url: String = "", method: String = "GET",
                headers: [String: String] = [:], bodyTemplate: String = "", params: [ToolParameter] = [],
                steps: [ToolStep] = [], requiresConfirmation: Bool = false, enabled: Bool = true,
                version: String = "1.0.0", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.title = title; self.summary = summary; self.kind = kind
        self.code = code; self.url = url; self.method = method; self.headers = headers
        self.bodyTemplate = bodyTemplate; self.params = params; self.steps = steps
        self.requiresConfirmation = requiresConfirmation; self.enabled = enabled
        self.version = version; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public var usesNetwork: Bool { kind == .http }

    public var spec: ToolSpec {
        ToolSpec(name: name, title: title, icon: kind.icon, description: summary,
                 parameters: params, requiresConfirmation: requiresConfirmation, usesNetwork: usesNetwork)
    }
}

public enum UserToolError: LocalizedError {
    case invalidName(String)
    case emptyField(String)
    case syntax(String)
    case insecureURL
    case badStatus(Int, String)
    case missingStep(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let n): return "اسم الأداة غير صالح: \(n) — استخدم حروفاً إنجليزية صغيرة وأرقاماً و_ فقط (٣–٤٠ حرفاً)."
        case .emptyField(let f): return "الحقل مطلوب: \(f)"
        case .syntax(let m): return "خطأ في الكود: \(m)"
        case .insecureURL: return "الرابط يجب أن يكون https (يُسمح بـ http للشبكة المحلية فقط)."
        case .badStatus(let c, let b): return "استجابة غير ناجحة (\(c)): \(b.prefix(200))"
        case .missingStep(let t): return "أداة غير موجودة في السلسلة: \(t)"
        }
    }
}

public enum ToolValidator {
    static let namePattern = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_]{2,39}$")

    public static func validate(_ t: UserTool, availableTools: Set<String>? = nil) throws {
        let range = NSRange(t.name.startIndex..<t.name.endIndex, in: t.name)
        guard namePattern.firstMatch(in: t.name, range: range) != nil else { throw UserToolError.invalidName(t.name) }
        guard !t.title.trimmingCharacters(in: .whitespaces).isEmpty else { throw UserToolError.emptyField("العنوان") }
        guard !t.summary.trimmingCharacters(in: .whitespaces).isEmpty else { throw UserToolError.emptyField("الوصف") }

        switch t.kind {
        case .javascript:
            guard !t.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UserToolError.emptyField("الكود") }
            try validateJavaScript(t.code)
        case .http:
            guard let u = URL(string: t.url), let scheme = u.scheme?.lowercased(), let host = u.host else {
                throw UserToolError.insecureURL
            }
            let local = host == "localhost" || host.hasPrefix("127.") || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.")
            if scheme != "https" && !(scheme == "http" && local) { throw UserToolError.insecureURL }
            if !["GET", "POST", "PUT", "PATCH", "DELETE"].contains(t.method.uppercased()) { throw UserToolError.emptyField("method") }
        case .workflow:
            guard !t.steps.isEmpty else { throw UserToolError.emptyField("الخطوات") }
            if let available = availableTools {
                for s in t.steps where !available.contains(s.tool) {
                    throw UserToolError.missingStep(s.tool)
                }
            }
        }
    }

    /// Compiles the body as a function to catch syntax errors before activation.
    public static func validateJavaScript(_ code: String) throws {
        #if canImport(JavaScriptCore)
        guard let ctx = JSContext() else { throw UserToolError.syntax("تعذّر إنشاء بيئة JavaScript") }
        var error: String?
        ctx.exceptionHandler = { _, e in error = e?.toString() }
        let wrapped = "var __sanad_tool = function(input){\(code)};"
        _ = ctx.evaluateScript(wrapped)
        if let error { throw UserToolError.syntax(error) }
        if ctx.objectForKeyedSubscript("__sanad_tool")?.isUndefined != false {
            throw UserToolError.syntax("تعذّر تحويل الكود إلى دالة")
        }
        #else
        throw UserToolError.syntax("JavaScriptCore غير متاح على هذه المنصة")
        #endif
    }
}

public final class UserToolStore {
    public static let shared = UserToolStore(fileName: "usertools.json")
    private let fileName: String?
    private let lock = NSLock()
    private var items: [UserTool]

    public init(fileName: String?) {
        self.fileName = fileName
        items = fileName.flatMap { Storage.load([UserTool].self, from: $0) } ?? []
    }

    public var all: [UserTool] { lock.lock(); defer { lock.unlock() }; return items }
    public var enabled: [UserTool] { all.filter(\.enabled) }
    public func tool(id: String) -> UserTool? { all.first { $0.id == id } }

    public func upsert(_ tool: UserTool) throws {
        try ToolValidator.validate(tool)
        var t = tool
        t.updatedAt = Date()
        lock.lock()
        if let i = items.firstIndex(where: { $0.id == t.id }) { items[i] = t } else { items.append(t) }
        lock.unlock()
        persist()
    }

    public func delete(_ id: String) {
        lock.lock(); items.removeAll { $0.id == id }; lock.unlock()
        persist()
    }

    public func setEnabled(_ id: String, _ on: Bool) {
        lock.lock()
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].enabled = on; items[i].updatedAt = Date() }
        lock.unlock()
        persist()
    }

    public func registerAll(into registry: ToolRegistry) {
        for t in enabled where t.kind != .workflow {
            UserToolRuntime.register(t, into: registry)
        }
        // Workflow tools may reference each other, so register them last.
        for t in enabled where t.kind == .workflow {
            UserToolRuntime.register(t, into: registry)
        }
    }

    private func persist() { if let f = fileName { Storage.save(all, to: f) } }
}

public enum UserToolRuntime {
    public static func register(_ tool: UserTool, into registry: ToolRegistry) {
        let captured = tool
        registry.register(ClosureTool(captured.spec) { args in
            try await run(captured, args, registry: registry)
        })
    }

    public static func run(_ tool: UserTool, _ args: ToolArguments, registry: ToolRegistry?) async throws -> String {
        switch tool.kind {
        case .javascript: return try runJavaScript(tool, args)
        case .http: return try await runHTTP(tool, args)
        case .workflow: return try await runWorkflow(tool, args, registry: registry)
        }
    }

    // MARK: JavaScript

    static func runJavaScript(_ tool: UserTool, _ args: ToolArguments) throws -> String {
        #if canImport(JavaScriptCore)
        let inputJSON = JSONValue.object(args).compactJSON
        guard let ctx = JSContext() else { throw UserToolError.syntax("تعذّر إنشاء بيئة JavaScript") }
        var logs: [String] = []
        let log: @convention(block) () -> Void = {
            let values = JSContext.currentArguments() as? [JSValue] ?? []
            logs.append(values.map { v -> String in
                if v.isObject, let json = v.context.objectForKeyedSubscript("JSON")?
                    .invokeMethod("stringify", withArguments: [v]), !json.isUndefined { return json.toString() }
                return v.toString() ?? ""
            }.joined(separator: " "))
        }
        let console = JSValue(newObjectIn: ctx)!
        for key in ["log", "info", "error", "warn"] { console.setObject(log, forKeyedSubscript: key as NSString) }
        ctx.setObject(console, forKeyedSubscript: "console" as NSString)

        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        ctx.evaluateScript("var __sanad_tool = function(input){\(tool.code)};")
        if let thrown { throw UserToolError.syntax(thrown) }
        guard let fn = ctx.objectForKeyedSubscript("__sanad_tool"),
              let input = ctx.evaluateScript("(\(inputJSON))"),
              let result = fn.call(withArguments: [input]) else {
            throw UserToolError.syntax("تعذّر تنفيذ الأداة")
        }
        if let thrown { throw UserToolError.syntax(thrown) }
        var out = logs.joined(separator: "\n")
        if !result.isUndefined && !result.isNull {
            let value = result.isObject ? (result.context.objectForKeyedSubscript("JSON")?
                .invokeMethod("stringify", withArguments: [result])?.toString() ?? result.toString() ?? "") : (result.toString() ?? "")
            if !value.isEmpty { out += (out.isEmpty ? "" : "\n") + value }
        }
        if out.count > 8000 { out = String(out.prefix(8000)) + "\n…(مقتطع)" }
        return out.isEmpty ? "(لا مخرجات — استخدم console.log أو return)" : out
        #else
        throw UserToolError.syntax("JavaScriptCore غير متاح")
        #endif
    }

    // MARK: HTTP

    static func runHTTP(_ tool: UserTool, _ args: ToolArguments) async throws -> String {
        try ToolValidator.validate(tool)
        let urlString = substitute(tool.url, args)
        guard let url = URL(string: urlString) else { throw UserToolError.insecureURL }
        var req = URLRequest(url: url)
        req.httpMethod = tool.method.uppercased()
        req.timeoutInterval = 30
        for (k, v) in tool.headers { req.setValue(substitute(v, args), forHTTPHeaderField: k) }
        if !tool.bodyTemplate.isEmpty && req.httpMethod != "GET" {
            req.httpBody = Data(substitute(tool.bodyTemplate, args).utf8)
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data.prefix(20_000), as: UTF8.self)
        guard (200..<300).contains(status) else { throw UserToolError.badStatus(status, body) }
        return body.isEmpty ? "(استجابة فارغة، \(status))" : body
    }

    // MARK: Workflow

    static func runWorkflow(_ tool: UserTool, _ args: ToolArguments, registry: ToolRegistry?) async throws -> String {
        guard let registry else { throw UserToolError.missingStep("السجل") }
        var outputs: [String] = []
        var last = ""
        for (index, step) in tool.steps.enumerated() {
            guard let target = registry.tool(named: step.tool) else { throw UserToolError.missingStep(step.tool) }
            var callArgs: ToolArguments = [:]
            for (key, template) in step.arguments {
                var value = substitute(template, args)
                if !outputs.isEmpty { value = value.replacingOccurrences(of: "{{previous}}", with: last) }
                callArgs[key] = .string(value)
            }
            last = try await target.run(callArgs)
            outputs.append(last)
            if last.count > 4000 { last = String(last.prefix(4000)) }
            _ = index
        }
        return outputs.enumerated().map { "الخطوة \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n---\n")
    }

    static func substitute(_ template: String, _ args: ToolArguments) -> String {
        var out = template
        for (k, v) in args {
            let value = v.stringValue ?? v.compactJSON
            out = out.replacingOccurrences(of: "{{input.\(k)}}", with: value)
        }
        return out
    }
}
