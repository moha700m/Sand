import Foundation

/// Which workspace the global tools operate on. Updated by AppState when the active agent changes.
public final class WorkspaceToolContext: @unchecked Sendable {
    private let lock = NSLock()
    private var _agentID: String
    public init(agentID: String = "default") { _agentID = agentID }
    public var agentID: String {
        get { lock.lock(); defer { lock.unlock() }; return _agentID }
        set { lock.lock(); _agentID = newValue; lock.unlock() }
    }
}

public enum WorkspaceTools {
    public static func register(into r: ToolRegistry, store: WorkspaceStore = .shared,
                                context: WorkspaceToolContext = WorkspaceToolContext()) {
        r.register(ClosureTool(ToolSpec(
            name: "workspace_list", title: "عرض ملفات مساحة العمل", icon: "folder",
            description: "List files and folders inside the agent workspace. Use an empty path for the root.",
            parameters: [ToolParameter("path", "string", "relative folder path", required: false)])) { a in
            let items = try store.list(context.agentID, at: a.string("path") ?? "")
            if items.isEmpty { return "المجلد فارغ." }
            return items.map { n in
                let size = n.isDirectory ? "\(n.childCount) عنصر" : ByteCountFormatter.string(fromByteCount: n.size, countStyle: .file)
                return "\(n.isDirectory ? "📁" : "📄") \(n.path) — \(size)"
            }.joined(separator: "\n")
        })

        r.register(ClosureTool(ToolSpec(
            name: "workspace_read", title: "قراءة ملف", icon: "doc.text",
            description: "Read a UTF-8 text file from the workspace.",
            parameters: [ToolParameter("path", "string", "relative file path")])) { a in
            guard let p = a.string("path"), !p.isEmpty else { throw ToolError("path مطلوب") }
            return try store.readText(context.agentID, p)
        })

        r.register(ClosureTool(ToolSpec(
            name: "workspace_write", title: "كتابة ملف", icon: "square.and.pencil",
            description: "Create or overwrite a text file in the workspace. Creates parent folders automatically.",
            parameters: [ToolParameter("path", "string", "relative file path, e.g. src/main.swift"),
                         ToolParameter("content", "string", "full file contents")])) { a in
            guard let p = a.string("path"), !p.isEmpty else { throw ToolError("path مطلوب") }
            let content = a.string("content") ?? ""
            guard !content.isEmpty else { throw ToolError("content مطلوب") }
            let url = try store.write(context.agentID, p, text: content)
            return "تم حفظ \(p) (\(ByteCountFormatter.string(fromByteCount: Int64(content.utf8.count), countStyle: .file))) في \(url.lastPathComponent)."
        })

        r.register(ClosureTool(ToolSpec(
            name: "workspace_append", title: "إضافة لملف", icon: "text.badge.plus",
            description: "Append text to an existing workspace file.",
            parameters: [ToolParameter("path", "string", "relative file path"),
                         ToolParameter("content", "string", "text to append")])) { a in
            guard let p = a.string("path") else { throw ToolError("path مطلوب") }
            _ = try store.append(context.agentID, p, text: (a.string("content") ?? "") + "\n")
            return "تمت الإضافة إلى \(p)."
        })

        r.register(ClosureTool(ToolSpec(
            name: "workspace_mkdir", title: "إنشاء مجلد", icon: "folder.badge.plus",
            description: "Create a folder inside the workspace.",
            parameters: [ToolParameter("path", "string", "relative folder path")])) { a in
            guard let p = a.string("path"), !p.isEmpty else { throw ToolError("path مطلوب") }
            _ = try store.createFolder(context.agentID, p)
            return "تم إنشاء المجلد \(p)."
        })

        r.register(ClosureTool(ToolSpec(
            name: "workspace_delete", title: "حذف ملف", icon: "trash",
            description: "Delete a file or folder from the workspace. Requires user approval.",
            parameters: [ToolParameter("path", "string", "relative path")],
            requiresConfirmation: true)) { a in
            guard let p = a.string("path"), !p.isEmpty else { throw ToolError("path مطلوب") }
            try store.delete(context.agentID, p)
            return "تم حذف \(p)."
        })

        r.register(ClosureTool(ToolSpec(
            name: "workspace_search", title: "البحث في الملفات", icon: "magnifyingglass",
            description: "Search file names and contents in the workspace.",
            parameters: [ToolParameter("query", "string", "text to find")])) { a in
            let hits = try store.search(context.agentID, query: a.string("query") ?? "")
            if hits.isEmpty { return "لا نتائج." }
            return hits.map { "\($0.path):\($0.line) — \($0.snippet)" }.joined(separator: "\n")
        })

        r.register(ClosureTool(ToolSpec(
            name: "workspace_zip", title: "تصدير ZIP", icon: "archivebox",
            description: "Package the workspace into a ZIP file in the app's temporary folder.")) { _ in
            let url = try store.exportZip(context.agentID)
            let bytes = (try? Data(contentsOf: url).count) ?? 0
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "تم إنشاء الأرشيف: \(url.lastPathComponent) (\(size))"
        })
    }
}
