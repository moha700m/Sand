import SwiftUI
import UniformTypeIdentifiers

/// Agents tab: pick an agent, give it a task, and forget about it.
/// Runs live in `AgentRunner`, so leaving this tab does not stop them.
struct AgentBuilderView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var runner: AgentRunner

    @State private var editing: AgentPackage?
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var error: String?
    @State private var path = NavigationPath()

    struct AgentRoute: Hashable { let id: String }
    struct JobRoute: Hashable { let id: UUID }

    var active: [AgentRunner.Job] { runner.activeJobs }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !active.isEmpty {
                    Section("قيد التنفيذ الآن") {
                        ForEach(active) { job in
                            NavigationLink(value: JobRoute(id: job.id)) { AgentJobRow(job: job) }
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("مهمة واحدة، والباقي علينا", systemImage: "shippingbox.fill").font(.headline)
                        Text("اختر وكيلاً واكتب المهمة. التشغيل يستمر في الخلفية حتى لو رجعت للرئيسية أو قفلت الشاشة، والنتيجة تُحفظ في المحادثات.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("الوكلاء (\(state.packages.count))") {
                    ForEach(state.packages) { pkg in
                        NavigationLink(value: AgentRoute(id: pkg.id)) { agentRow(pkg) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { state.deleteAgent(pkg.id) } label: {
                                    Label("حذف", systemImage: "trash")
                                }
                                Button { editing = pkg } label: { Label("تعديل", systemImage: "pencil") }
                                    .tint(.blue)
                            }
                            .contextMenu {
                                Button { duplicate(pkg) } label: { Label("نسخة", systemImage: "plus.square.on.square") }
                                Button { export(pkg) } label: { Label("تصدير حزمة", systemImage: "square.and.arrow.up") }
                            }
                    }
                }

                if !runner.finishedJobs.isEmpty {
                    Section {
                        ForEach(runner.finishedJobs.prefix(6)) { job in
                            NavigationLink(value: JobRoute(id: job.id)) { AgentJobRow(job: job) }
                        }
                        Button("مسح السجل") { runner.clearFinished() }
                            .font(.footnote)
                    } header: {
                        Text("آخر المهام")
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
            .navigationDestination(for: AgentRoute.self) { route in
                if let pkg = state.packages.first(where: { $0.id == route.id }) {
                    AgentRunView(agent: pkg.profile())
                } else {
                    ContentUnavailableView("الوكيل غير موجود", systemImage: "questionmark.folder",
                                           description: Text("ربما حُذف. ارجع للقائمة."))
                }
            }
            .navigationDestination(for: JobRoute.self) { route in
                AgentJobDetailView(jobID: route.id)
            }
            .sheet(item: $editing) { pkg in AgentEditor3(pkg: pkg) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .folder]) { result in
                if case .success(let url) = result {
                    do {
                        let pkg = try state.agentPackages.importPackage(from: url)
                        state.packages = state.agentPackages.all
                        editing = pkg
                    } catch { self.error = error.localizedDescription }
                }
            }
            .sheet(item: Binding(get: { exportURL.map { ExportTarget(url: $0) } },
                                 set: { if $0 == nil { exportURL = nil } })) { target in
                ShareSheet(url: target.url).presentationDetents([.medium])
            }
            .onAppear(perform: openPendingAgent)
            .onChange(of: state.pendingAgentID) { _, _ in openPendingAgent() }
        }
    }

    struct ExportTarget: Identifiable { let id = UUID(); let url: URL }

    func agentRow(_ pkg: AgentPackage) -> some View {
        HStack(spacing: 12) {
            Image(systemName: pkg.icon)
                .font(.title3)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(pkg.name).font(.headline)
                Text(pkg.summary.isEmpty ? "بدون وصف" : pkg.summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(meta(pkg)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if runner.activeJob(for: pkg.id) != nil {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    func meta(_ pkg: AgentPackage) -> String {
        let tools = pkg.tools.contains("*") ? "كل الأدوات" : "\(pkg.tools.count) أداة"
        return "\(tools) · حتى \(pkg.maxSteps) خطوة" + (pkg.allowNetwork ? " · شبكة" : "")
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

    func openPendingAgent() {
        guard let id = state.pendingAgentID else { return }
        state.pendingAgentID = nil
        guard state.packages.contains(where: { $0.id == id }) else { return }
        path = NavigationPath()
        path.append(AgentRoute(id: id))
    }
}

struct AgentJobRow: View {
    let job: AgentRunner.Job

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.agentIcon)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.goal).font(.subheadline).lineLimit(1)
                Text("\(job.agentName) · \(job.state.title)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if job.state == .running {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: job.state.icon)
                    .font(.caption)
                    .foregroundStyle(job.state == .done ? Color.green : Color.secondary)
            }
        }
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
