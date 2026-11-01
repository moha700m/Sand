import SwiftUI
import UniformTypeIdentifiers

/// Agent Builder: packages are portable, versioned, and runnable.
struct AgentBuilderView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: AgentPackage?
    @State private var running: AgentPackage?
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("وكلاء بحزم قابلة للنقل", systemImage: "shippingbox.fill").font(.headline)
                        Text("كل وكيل: تعليمات + أدوات + مهارات + حد خطوات + صلاحيات. صدّره كملف .sanadagent واستورده على جهاز آخر.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("الوكلاء (\(state.packages.count))") {
                    ForEach(state.packages) { pkg in
                        row(pkg)
                    }
                }

                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("الوكلاء")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                    Button { newAgent() } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { pkg in
                AgentEditor3(pkg: pkg)
            }
            .sheet(item: $running) { pkg in
                NavigationStack {
                    AgentRunView(agent: pkg.profile())
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("إغلاق") { running = nil }
                            }
                        }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .folder]) { result in
                if case .success(let url) = result {
                    do {
                        let pkg = try state.agentPackages.importPackage(from: url)
                        state.packages = state.agentPackages.all
                        editing = pkg
                    } catch { self.error = error.localizedDescription }
                }
            }
            .sheet(item: Binding(get: { exportURL.map { ExportTarget(url: $0) } }, set: { if $0 == nil { exportURL = nil } })) { t in
                ShareSheet(url: t.url).presentationDetents([.medium])
            }
        }
    }

    struct ExportTarget: Identifiable { let id = UUID(); let url: URL }

    func row(_ pkg: AgentPackage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: pkg.icon).font(.title3)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(pkg.name).font(.headline)
                    Text(pkg.summary.isEmpty ? "بدون وصف" : pkg.summary)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                chip(pkg.tools.contains("*") ? "كل الأدوات" : "\(pkg.tools.count) أداة")
                chip("\(pkg.maxSteps) خطوة")
                if pkg.allowNetwork { chip("شبكة") } else { chip("بدون إنترنت") }
                if !pkg.skillIDs.isEmpty { chip("\(pkg.skillIDs.count) مهارة") }
            }
            HStack {
                Button("تشغيل") { running = pkg }.buttonStyle(.borderedProminent).controlSize(.small)
                Button("تعديل") { editing = pkg }.buttonStyle(.bordered).controlSize(.small)
                Menu {
                    Button { duplicate(pkg) } label: { Label("نسخة", systemImage: "plus.square.on.square") }
                    Button { export(pkg) } label: { Label("تصدير حزمة", systemImage: "square.and.arrow.up") }
                    Divider()
                    Button(role: .destructive) { state.deleteAgent(pkg.id) } label: { Label("حذف", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis") }
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    func chip(_ t: String) -> some View {
        Text(t).font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    func newAgent() {
        editing = AgentPackage(name: "وكيل جديد", summary: "ماذا يفعل هذا الوكيل؟",
                               instructions: "أنت وكيل متخصص. اشرح خطتك ثم استخدم الأدوات.",
                               tools: ["*"], maxSteps: 8)
    }

    func duplicate(_ pkg: AgentPackage) {
        if let copy = state.agentPackages.duplicate(pkg.id) {
            state.packages = state.agentPackages.all
            editing = copy
        }
    }

    func export(_ pkg: AgentPackage) {
        do { exportURL = try state.agentPackages.export(pkg.id) }
        catch { self.error = error.localizedDescription }
    }
}

struct AgentEditor3: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State var pkg: AgentPackage
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("الهوية") {
                    TextField("الاسم", text: $pkg.name)
                    TextField("الوصف", text: $pkg.summary, axis: .vertical)
                    TextField("أيقونة SF Symbol", text: $pkg.icon)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }

                Section("التعليمات") {
                    TextEditor(text: $pkg.instructions)
                        .frame(minHeight: 160)
                        .font(.callout)
                }

                Section("النموذج") {
                    Picker("Model", selection: $pkg.modelRef) {
                        Text("محلي (على الجهاز)").tag("local")
                        ForEach(state.providers) { p in
                            Text(p.displayName).tag(p.id)
                        }
                    }
                    Stepper("حد الخطوات: \(pkg.maxSteps)", value: $pkg.maxSteps, in: 1...30)
                }

                Section("الأدوات") {
                    NavigationLink {
                        ToolSelectionList(selection: $pkg.tools)
                    } label: {
                        HStack {
                            Text("أدوات الوكيل")
                            Spacer()
                            Text(pkg.tools.contains("*") ? "الكل" : "\(pkg.tools.count)").foregroundStyle(.secondary)
                        }
                    }
                }

                Section("المهارات") {
                    NavigationLink {
                        SkillSelectionList(selection: $pkg.skillIDs)
                    } label: {
                        HStack {
                            Text("مهارات محمّلة")
                            Spacer()
                            Text("\(pkg.skillIDs.count)").foregroundStyle(.secondary)
                        }
                    }
                }

                Section("الصلاحيات") {
                    Toggle("السماح بالشبكة", isOn: $pkg.allowNetwork)
                    Toggle("السماح بكتابة الملفات", isOn: $pkg.allowFileWrite)
                    Toggle("تفضيل العمل دون إنترنت", isOn: $pkg.offlineOnly)
                }

                Section("الحزمة") {
                    LabeledContent("المعرّف", value: String(pkg.id.prefix(8)) + "…")
                    LabeledContent("الإصدار", value: pkg.version)
                }

                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("تعديل وكيل")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        do { try state.savePackage(pkg); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.bold()
                }
            }
        }
    }
}

struct ToolSelectionList: View {
    @EnvironmentObject var state: AppState
    @Binding var selection: [String]

    var all: Bool { selection.contains("*") }

    var body: some View {
        List {
            Section {
                Toggle("كل الأدوات (بما فيها أدوات MCP)", isOn: Binding(
                    get: { all },
                    set: { on in selection = on ? ["*"] : [] }))
            }
            Section("الأدوات المتاحة") {
                ForEach(state.registry.specs) { spec in
                    Button {
                        toggle(spec.name)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(spec.title)
                                Text(spec.name).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if all || selection.contains(spec.name) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("أدوات الوكيل")
    }

    func toggle(_ name: String) {
        if all { selection = [name]; return }
        if let i = selection.firstIndex(of: name) { selection.remove(at: i) } else { selection.append(name) }
    }
}

struct SkillSelectionList: View {
    @EnvironmentObject var state: AppState
    @Binding var selection: [String]

    var body: some View {
        List {
            if state.skills.all.isEmpty {
                Text("لا مهارات مثبتة.").foregroundStyle(.secondary)
            }
            ForEach(state.skills.all) { skill in
                Button {
                    if let i = selection.firstIndex(of: skill.id) { selection.remove(at: i) } else { selection.append(skill.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name)
                            Text(skill.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if selection.contains(skill.id) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("المهارات")
    }
}
