import Foundation

/// Coarse capability classes used to gate tool execution.
public enum ToolPermission: String, Codable, CaseIterable, Sendable {
    case readLocal, writeLocal, network, system

    public var title: String {
        switch self {
        case .readLocal: return "قراءة محلية"
        case .writeLocal: return "كتابة محلية"
        case .network: return "شبكة"
        case .system: return "تعديل على النظام"
        }
    }

    public var icon: String {
        switch self {
        case .readLocal: return "doc.text.magnifyingglass"
        case .writeLocal: return "square.and.pencil"
        case .network: return "network"
        case .system: return "exclamationmark.shield"
        }
    }
}

/// Decides whether a tool may run for a given agent, and whether the user must confirm.
public struct PermissionPolicy: Codable, Equatable, Sendable {
    public var allowNetwork: Bool
    public var allowFileWrite: Bool
    public var allowSystemActions: Bool
    /// Tools outside this prefix list are refused. `["*"]` means everything.
    public var allowedPrefixes: [String]

    public init(allowNetwork: Bool = false, allowFileWrite: Bool = true,
                allowSystemActions: Bool = true, allowedPrefixes: [String] = ["*"]) {
        self.allowNetwork = allowNetwork
        self.allowFileWrite = allowFileWrite
        self.allowSystemActions = allowSystemActions
        self.allowedPrefixes = allowedPrefixes
    }

    public static let local = PermissionPolicy()
    public static let research = PermissionPolicy(allowNetwork: true)
    public static let readOnly = PermissionPolicy(allowFileWrite: false, allowSystemActions: false)

    public func allows(tool name: String) -> Bool {
        if allowedPrefixes.contains("*") { return true }
        if allowedPrefixes.contains(name) { return true }
        return allowedPrefixes.contains { p in p.hasSuffix("*") && name.hasPrefix(String(p.dropLast())) }
    }
}

public enum PermissionManager {
    /// Deterministic classification, so the UI can explain *why* a tool needs approval.
    public static func permission(for spec: ToolSpec) -> ToolPermission {
        let n = spec.name.lowercased()
        if spec.usesNetwork || n.hasPrefix("http") || n == "web_search" || n == "fetch_url" || n.hasPrefix("mcp_") { return .network }
        if n.contains("create_reminder") || n.contains("create_event") || n.contains("run_javascript") { return .system }
        if n.hasPrefix("workspace_") {
            return n.contains("write") || n.contains("append") || n.contains("delete") || n.contains("mkdir") || n.contains("rename") ? .writeLocal : .readLocal
        }
        if n.contains("notes_add") || n.contains("memory_save") { return .writeLocal }
        return .readLocal
    }

    public static func requiresConfirmation(_ spec: ToolSpec) -> Bool {
        if spec.requiresConfirmation { return true }
        switch permission(for: spec) {
        case .system: return true
        case .network: return false   // network is gated by policy, not per-call prompts
        case .writeLocal, .readLocal: return false
        }
    }

    public static func denialReason(_ spec: ToolSpec, policy: PermissionPolicy) -> String? {
        guard policy.allows(tool: spec.name) else { return "الأداة \(spec.name) خارج قائمة أدوات هذا الوكيل." }
        switch permission(for: spec) {
        case .network:
            if policy.allowNetwork { return nil }
            return "هذا الوكيل يعمل دون شبكة. فعّل الشبكة من إعدادات الوكيل للسماح بـ \(spec.title)."
        case .writeLocal:
            return policy.allowFileWrite ? nil : "الكتابة على الملفات معطّلة لهذا الوكيل."
        case .system:
            return policy.allowSystemActions ? nil : "هذا الوكيل لا يملك صلاحية تعديل بيانات النظام."
        case .readLocal:
            return nil
        }
    }
}
