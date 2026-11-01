import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Sandboxed file browser + editor for the active agent workspace.
struct WorkspaceView: View {
    @EnvironmentObject var state: AppState
    @State private var path = ""
    @State private var nodes: [FileNode] = []
    @State private var error: String?
    @State private var editor: EditorTarget?
    @State private var showNewFile = false
    @State private var showNewFolder = false
    @State private var newName = ""
    @State private var pendingDelete: FileNode?
    @State private var exportURL: URL?
    @State private var search = ""

    struct EditorTarget: Identifiable {
        let id = UUID()
        var path: String
        var text: String
        var isNew: Bool
    }

    var agentID: String { state.workspaceContext.agentID }

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.orange)
                    Text(path.isEmpty ? "الجذر" : path).font(.footnote.monospaced()).lineLimit(1)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: state.workspace.totalBytes(agentID), countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !search.isEmpty {
                    ForEach(searchResults) { hit in
                        Button {
                            open(hit.path)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.path).font(.footnote)
                                Text(hit.snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !path.isEmpty {
                Button {
                    path = parent(path)
                } label: { Label("أعلى مستوى", systemImage: "arrow.up.left") }
            }

            Section("الملفات") {
                if nodes.isEmpty && error == nil {
                    Text("لا ملفات بعد. أنشئ ملفاً أو اطلب من سَنَد إنشاء مشروع.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(nodes) { node in
                    if node.isDirectory {
                        Button { path = node.path } label: {
                            HStack {
                                Label(node.name, systemImage: "folder")
                                Spacer()
                                Text("\(node.childCount)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button { open(node.path) } label: {
                            HStack {
                                Label(node.name, systemImage: icon(for: node.name))
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { pendingDelete = node } label: { Label("حذف", systemImage: "trash") }
                        }
                    }
                }
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .searchable(text: $search, prompt: "ابحث في ملفات مساحة العمل")
        .navigationTitle("مساحة العمل")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button { newName = ""; showNewFile = true } label: { Label("ملف جديد", systemImage: "doc.badge.plus") }
                    Button { newName = ""; showNewFolder = true } label: { Label("مجلد جديد", systemImage: "folder.badge.plus") }
                    Divider()
                    Button { exportWorkspace() } label: { Label("تصدير ZIP", systemImage: "archivebox") }
                } label: { Image(systemName: "plus") }
            }
        }
        .refreshable { reload() }
        .onAppear(perform: reload)
        .onChange(of: path) { _, _ in reload() }
        .alert("ملف جديد", isPresented: $showNewFile) {
            TextField("main.swift", text: $newName)
            Button("إنشاء") { createFile() }
            Button("إلغاء", role: .cancel) {}
        }
        .alert("مجلد جديد", isPresented: $showNewFolder) {
            TextField("src", text: $newName)
            Button("إنشاء") { createFolder() }
            Button("إلغاء", role: .cancel) {}
        }
        .confirmationDialog("حذف \(pendingDelete?.name ?? "")؟", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("حذف نهائي", role: .destructive) { deletePending() }
            Button("إلغاء", role: .cancel) { pendingDelete = nil }
        }
        .sheet(item: $editor) { target in
            EditorSheet(target: target) { text in save(target, text) }
        }
        .sheet(item: Binding(get: { exportURL.map { ExportItem(url: $0) } }, set: { if $0 == nil { exportURL = nil } })) { item in
            ShareSheet(url: item.url)
                .presentationDetents([.medium])
        }
    }

    struct ExportItem: Identifiable { let id = UUID(); let url: URL }

    var searchResults: [WorkspaceSearchHit] {
        (try? state.workspace.search(agentID, query: search, limit: 25)) ?? []
    }

    func reload() {
        do {
            nodes = try state.workspace.list(agentID, at: path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func open(_ p: String) {
        do {
            let text = try state.workspace.readText(agentID, p)
            editor = EditorTarget(path: p, text: text, isNew: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func save(_ target: EditorTarget, _ text: String) {
        do {
            _ = try state.workspace.write(agentID, target.path, text: text)
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createFile() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let full = path.isEmpty ? name : path + "/" + name
        do {
            _ = try state.workspace.write(agentID, full, text: "")
            reload()
            editor = EditorTarget(path: full, text: "", isNew: true)
        } catch { self.error = error.localizedDescription }
    }

    func createFolder() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            _ = try state.workspace.createFolder(agentID, path.isEmpty ? name : path + "/" + name)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func deletePending() {
        guard let node = pendingDelete else { return }
        do { try state.workspace.delete(agentID, node.path); reload() }
        catch { self.error = error.localizedDescription }
        pendingDelete = nil
    }

    func exportWorkspace() {
        do { exportURL = try state.workspace.exportZip(agentID) }
        catch { self.error = error.localizedDescription }
    }

    func parent(_ p: String) -> String {
        let comps = p.split(separator: "/")
        return comps.dropLast().joined(separator: "/")
    }

    func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md": return "doc.richtext"
        case "json": return "curlybraces"
        case "html", "css", "js": return "chevron.left.forwardslash.chevron.right"
        case "csv": return "tablecells"
        case "py": return "terminal"
        default: return "doc.text"
        }
    }
}

struct EditorSheet: View {
    let target: WorkspaceView.EditorTarget
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(target: WorkspaceView.EditorTarget, onSave: @escaping (String) -> Void) {
        self.target = target
        self.onSave = onSave
        _text = State(initialValue: target.text)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .environment(\.layoutDirection, .leftToRight)
                .padding(8)
                .navigationTitle(target.path)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("حفظ") { onSave(text); dismiss() }.bold()
                    }
                }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
