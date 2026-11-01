import SwiftUI
import UniformTypeIdentifiers

struct SkillsView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: SkillPackage?
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("المهارة ملف SKILL.md: تعليمات + أدوات مطلوبة + مدخلات. تُحمّل داخل الوكيل عند الحاجة، ولا تُنفّذ كوداً.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(SkillCategory.allCases) { cat in
                    let items = state.skills.all.filter { $0.category == cat }
                    if !items.isEmpty {
                        Section(cat.title) {
                            ForEach(items) { skill in row(skill) }
                        }
                    }
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("المهارات")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                }
            }
            .sheet(item: $editing) { s in SkillEditor(skill: s) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
                if case .success(let url) = result { install(url) }
            }
            .sheet(item: Binding(get: { exportURL.map { Target(url: $0) } }, set: { if $0 == nil { exportURL = nil } })) { t in
                ShareSheet(url: t.url).presentationDetents([.medium])
            }
        }
    }

    struct Target: Identifiable { let id = UUID(); let url: URL }

    func row(_ skill: SkillPackage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(skill.name).font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { skill.enabled },
                    set: { state.skills.setEnabled(skill.id, $0) })).labelsHidden()
            }
            Text(skill.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack(spacing: 6) {
                Text(skill.version).font(.caption2).foregroundStyle(.secondary)
                if !skill.tools.isEmpty {
                    Text("\(skill.tools.count) أداة").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Spacer()
                Button("عرض") { editing = skill }.buttonStyle(.bordered).controlSize(.mini)
                Button("تصدير") {
                    if let url = state.skills.export(skill.id) { exportURL = url }
                }.buttonStyle(.bordered).controlSize(.mini)
            }
        }
        .padding(.vertical, 3)
        .swipeActions {
            if !skill.builtIn {
                Button(role: .destructive) { state.skills.delete(skill.id) } label: { Label("حذف", systemImage: "trash") }
            }
        }
    }

    func install(_ url: URL) {
        do {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                _ = try state.skills.importFolder(url)
            } else {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let text = try String(contentsOf: url, encoding: .utf8)
                guard state.skills.installFromText(text, fallbackName: url.deletingPathExtension().lastPathComponent) != nil else {
                    throw ToolError("تعذّر تحليل SKILL.md")
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct SkillEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State var skill: SkillPackage
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("البيانات") {
                    TextField("الاسم", text: $skill.name)
                    TextField("الوصف", text: $skill.summary, axis: .vertical)
                    Picker("التصنيف", selection: $skill.category) {
                        ForEach(SkillCategory.allCases) { c in Text(c.title).tag(c) }
                    }
                }
                Section("التعليمات") {
                    TextEditor(text: $skill.body)
                        .frame(minHeight: 260)
                        .font(.callout)
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(skill.builtIn ? "مهارة مدمجة" : "تعديل مهارة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        guard !skill.body.trimmingCharacters(in: .whitespaces).isEmpty else {
                            error = "التعليمات مطلوبة"; return
                        }
                        _ = state.skills.upsert(skill)
                        dismiss()
                    }.bold()
                }
            }
        }
    }
}
