import SwiftUI

/// Tool builder: author JavaScript, HTTP or chained tools, validate them, and test them for real.
struct ToolsView: View {
    @EnvironmentObject var state: AppState
    @State private var segment = 0
    @State private var editing: UserTool?
    @State private var testing: UserTool?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Picker("", selection: $segment) {
                    Text("أدواتي").tag(0)
                    Text("المدمجة").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }

            if segment == 0 {
                if state.userTools.all.isEmpty {
                    Section {
                        Text("لم تصنع أدوات بعد. الأداة = اسم + وصف + كود JavaScript أو طلب HTTP، وتصبح متاحة للوكلاء.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("منشأة") {
                    ForEach(state.userTools.all) { tool in
                        row(tool)
                    }
                }
            } else {
                Section("أدوات مدمجة (\(state.registry.specs.count))") {
                    ForEach(state.registry.specs) { spec in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label(spec.title, systemImage: spec.icon)
                                Spacer()
                                Text(spec.name).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Text(spec.description).font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                tag(PermissionManager.permission(for: spec).title)
                                if spec.usesNetwork { tag("شبكة") }
                                if spec.requiresConfirmation { tag("يتطلب موافقة") }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("الأدوات")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { newTool() } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing) { tool in
            ToolEditor(tool: tool) { saved in
                do {
                    try state.userTools.upsert(saved)
                    state.registry.unregister(name: saved.name)
                    UserToolRuntime.register(saved, into: state.registry)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .sheet(item: $testing) { tool in
            ToolTestSheet(tool: tool)
        }
    }

    func row(_ tool: UserTool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: tool.kind.icon).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.title).font(.headline)
                    Text(tool.name).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { tool.enabled },
                    set: { on in
                        state.userTools.setEnabled(tool.id, on)
                        if on { UserToolRuntime.register(tool, into: state.registry) }
                        else { state.registry.unregister(name: tool.name) }
                    }))
                    .labelsHidden()
            }
            Text(tool.summary).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                tag(tool.kind.title)
                if tool.requiresConfirmation { tag("يتطلب موافقة") }
                if tool.usesNetwork { tag("شبكة") }
            }
            HStack {
                Button("اختبار") { testing = tool }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("تعديل") { editing = tool }
                    .buttonStyle(.bordered).controlSize(.small)
                Spacer()
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            Button(role: .destructive) {
                state.registry.unregister(name: tool.name)
                state.userTools.delete(tool.id)
            } label: { Label("حذف", systemImage: "trash") }
        }
    }

    func tag(_ text: String) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    func newTool() {
        editing = UserTool(name: "new_tool", title: "أداة جديدة", summary: "",
                           kind: .javascript, code: "console.log(input);\nreturn \"تم\";")
    }
}

struct ToolEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var tool: UserTool
    @State private var paramsText = ""
    @State private var stepsText = ""
    @State private var error: String?
    var onSave: (UserTool) -> Void

    init(tool: UserTool, onSave: @escaping (UserTool) -> Void) {
        _tool = State(initialValue: tool)
        self.onSave = onSave
        _paramsText = State(initialValue: tool.params.map { "\($0.name)|\($0.type)|\($0.description)" }.joined(separator: "\n"))
        _stepsText = State(initialValue: tool.steps.map { s in
            "\(s.tool)|" + s.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        }.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("الهوية") {
                    TextField("name_with_underscores", text: $tool.name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("العنوان", text: $tool.title)
                    TextField("الوصف الذي يقرأه النموذج", text: $tool.summary, axis: .vertical)
                    Picker("النوع", selection: $tool.kind) {
                        ForEach(UserToolKind.allCases) { k in
                            Label(k.title, systemImage: k.icon).tag(k)
                        }
                    }
                }

                Section("المعاملات") {
                    Text("سطر لكل معامل: name|type|description")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextEditor(text: $paramsText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 80)
                        .environment(\.layoutDirection, .leftToRight)
                }

                switch tool.kind {
                case .javascript:
                    Section("الكود (JavaScript)") {
                        Text("المتغير input يحتوي المعاملات. اطبع بـ console.log أو استخدم return.")
                            .font(.caption2).foregroundStyle(.secondary)
                        TextEditor(text: $tool.code)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 160)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                case .http:
                    Section("HTTP") {
                        TextField("https://api.example.com/v1/...", text: $tool.url)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .environment(\.layoutDirection, .leftToRight)
                        Picker("Method", selection: $tool.method) {
                            ForEach(["GET", "POST", "PUT", "PATCH", "DELETE"], id: \.self) { Text($0) }
                        }
                        TextField("Body (JSON)", text: $tool.bodyTemplate, axis: .vertical)
                            .environment(\.layoutDirection, .leftToRight)
                        Text("استخدم {{input.key}} داخل الرابط أو الجسم.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                case .workflow:
                    Section("الخطوات") {
                        Text("سطر لكل خطوة: tool_name|key={{input.x}}")
                            .font(.caption2).foregroundStyle(.secondary)
                        TextEditor(text: $stepsText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 120)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }

                Section("الصلاحيات") {
                    Toggle("يتطلب موافقة قبل التنفيذ", isOn: $tool.requiresConfirmation)
                }

                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("منشئ الأدوات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") { save() }.bold()
                }
            }
        }
    }

    func save() {
        tool.params = paramsText.components(separatedBy: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 1, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let type = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "string"
            let desc = parts.count > 2 ? parts[2] : name
            return ToolParameter(name, type.isEmpty ? "string" : type, desc)
        }
        tool.steps = stepsText.components(separatedBy: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let first = parts.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty else { return nil }
            var args: [String: String] = [:]
            if parts.count > 1 {
                for pair in parts[1].split(separator: ",") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2 { args[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces) }
                }
            }
            return ToolStep(tool: first, arguments: args)
        }
        do {
            try ToolValidator.validate(tool)
            onSave(tool)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ToolTestSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let tool: UserTool
    @State private var input = "{}"
    @State private var output = ""
    @State private var running = false

    var body: some View {
        NavigationStack {
            Form {
                Section("المدخلات (JSON)") {
                    TextEditor(text: $input)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 100)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Section {
                    Button {
                        Task { await run() }
                    } label: {
                        HStack { if running { ProgressView().controlSize(.small) }; Text(running ? "جاري التنفيذ…" : "تنفيذ") }
                    }
                    .disabled(running)
                }
                Section("الناتج") {
                    Text(output.isEmpty ? "—" : output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .navigationTitle(tool.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }
    }

    func run() async {
        running = true
        defer { running = false }
        var args: ToolArguments = [:]
        if let d = input.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in obj {
                if let s = v as? String { args[k] = .string(s) }
                else if let n = v as? NSNumber { args[k] = .number(n.doubleValue) }
                else if let b = v as? Bool { args[k] = .bool(b) }
            }
        }
        do { output = try await UserToolRuntime.run(tool, args, registry: state.registry) }
        catch { output = "خطأ: \(error.localizedDescription)" }
    }
}
