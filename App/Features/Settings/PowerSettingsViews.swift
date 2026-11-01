import SwiftUI

// MARK: - Cloud providers

struct ProvidersView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var editing: ProviderConfig?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("نماذج سحابية أقوى", systemImage: "cloud.bolt.fill").font(.headline)
                    Text("أضف مفتاحك من OpenAI أو Anthropic أو Google أو OpenRouter أو Groq أو DeepSeek، أو أي خادم متوافق مع OpenAI (مثل LM Studio وOllama على جهازك). المفاتيح تُحفظ في Keychain على جهازك فقط، والمحادثات تُرسل مباشرة للمزود.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("النموذج الافتراضي") {
                Picker("الافتراضي", selection: $settings.defaultModelRef) {
                    Text("محلي — \(state.models.activeModel?.name ?? "على الجهاز")").tag("local")
                    ForEach(state.providers) { Text($0.displayName).tag($0.id) }
                }
            }
            Section("المزودون") {
                ForEach(state.providers) { p in
                    Button { editing = p } label: {
                        HStack {
                            Image(systemName: "cloud.fill").foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(p.name).foregroundStyle(.primary)
                                Text(p.model).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if state.isReady(p.id) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            } else {
                                Text("بدون مفتاح").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    .swipeActions { Button(role: .destructive) { state.deleteProvider(p) } label: { Label("حذف", systemImage: "trash") } }
                }
                Menu {
                    ForEach(ProviderKind.allCases) { k in
                        Button(k.title) { editing = ProviderConfig(kind: k) }
                    }
                } label: { Label("إضافة مزود", systemImage: "plus.circle.fill") }
            }
        }
        .navigationTitle("مزودو السحابة")
        .sheet(item: $editing) { p in ProviderEditor(config: p) }
    }
}

struct ProviderEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State var config: ProviderConfig
    @State private var key = ""
    @State private var models: [String] = []
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("المزود") {
                    LabeledContent("النوع", value: config.kind.title)
                    TextField("الاسم", text: $config.name)
                    TextField("الرابط", text: $config.baseURL).keyboardType(.URL).textInputAutocapitalization(.never)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Section("مفتاح API") {
                    SecureField(Keychain.get(config.keychainKey) == nil ? "الصق المفتاح هنا" : "•••••••• (محفوظ — اتركه فارغاً للإبقاء)", text: $key)
                        .textInputAutocapitalization(.never).environment(\.layoutDirection, .leftToRight)
                }
                Section("النموذج") {
                    TextField("اسم النموذج", text: $config.model).textInputAutocapitalization(.never)
                        .environment(\.layoutDirection, .leftToRight)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(models.isEmpty ? config.kind.suggestedModels : models, id: \.self) { m in
                                Button(m) { config.model = m }.buttonStyle(.bordered).controlSize(.small)
                                    .tint(config.model == m ? .accentColor : .gray)
                            }
                        }
                    }
                    Button { Task { await fetchModels() } } label: { Label("جلب قائمة النماذج من المزود", systemImage: "arrow.down.circle") }
                }
                Section {
                    Button { Task { await test() } } label: {
                        HStack { Label("اختبار الاتصال", systemImage: "bolt.horizontal.circle"); if testing { Spacer(); ProgressView() } }
                    }
                    if let result { Text(result).font(.footnote).foregroundStyle(result.hasPrefix("✓") ? .green : .red) }
                }
            }
            .navigationTitle(config.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        state.saveProvider(config, key: key.isEmpty ? nil : key)
                        if state.providers.count == 1 { state.settings.defaultModelRef = config.id }
                        dismiss()
                    }
                    .disabled(config.model.isEmpty)
                }
            }
        }
    }

    var effectiveKey: String { key.isEmpty ? (Keychain.get(config.keychainKey) ?? "") : key }

    func fetchModels() async {
        do { models = try await CloudBackend.fetchModels(config: config, apiKey: effectiveKey); result = "✓ \(models.count) نموذج" }
        catch { result = error.localizedDescription }
    }

    func test() async {
        testing = true; result = nil
        let b = CloudBackend(config: config, apiKey: effectiveKey)
        do {
            var s = GenerationSettings(); s.maxTokens = 40
            let (t, stats) = try await b.generate(messages: [ChatMessage(role: .user, content: "قل: أهلاً من سَنَد")], settings: s, stop: []) { _ in true }
            result = "✓ " + String(t.prefix(80)) + String(format: " (%.1f ث)", stats.seconds)
        } catch { result = error.localizedDescription }
        testing = false
    }
}

// MARK: - MCP servers

struct MCPServersView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var mcp: MCPManager
    @State private var editing: MCPServerConfig?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Model Context Protocol", systemImage: "puzzlepiece.extension.fill").font(.headline)
                    Text("اربط سَنَد بأي خادم MCP عن بُعد (Streamable HTTP) لتصبح أدواته متاحة للوكلاء تلقائياً: GitHub، Notion، قواعد بيانات، بحث، وأكثر. جرّب DeepWiki لسؤال أي مستودع GitHub.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("الخوادم") {
                ForEach(mcp.servers) { s in
                    let st = mcp.status[s.id] ?? .init()
                    HStack(spacing: 12) {
                        Circle().fill(st.connected ? Color.green : st.error != nil ? Color.red : Color.gray).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.headline)
                            Text(s.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            if st.busy { Text("جاري الاتصال…").font(.caption2) }
                            else if st.connected { Text("\(st.toolCount) أداة متاحة للوكلاء").font(.caption2).foregroundStyle(.green) }
                            else if let e = st.error { Text(e).font(.caption2).foregroundStyle(.red).lineLimit(2) }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { s.enabled }, set: { mcp.setEnabled(s, $0) })).labelsHidden()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = s }
                    .swipeActions {
                        Button(role: .destructive) { mcp.remove(s) } label: { Label("حذف", systemImage: "trash") }
                        Button { Task { await mcp.connect(s) } } label: { Label("تحديث", systemImage: "arrow.clockwise") }.tint(.blue)
                    }
                }
                Button { editing = MCPServerConfig(name: "", url: "https://") } label: { Label("إضافة خادم MCP", systemImage: "plus.circle.fill") }
            }
            if mcp.totalTools > 0 {
                Section("الأدوات المكتشفة") {
                    ForEach(state.registry.specs.filter { $0.name.hasPrefix("mcp_") }) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.subheadline.weight(.semibold))
                            Text(t.description).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle("خوادم MCP")
        .sheet(item: $editing) { s in MCPServerEditor(server: s, mcp: mcp) }
    }
}

struct MCPServerEditor: View {
    @Environment(\.dismiss) var dismiss
    @State var server: MCPServerConfig
    @ObservedObject var mcp: MCPManager
    @State private var header = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("الخادم") {
                    TextField("الاسم (مثل GitHub)", text: $server.name)
                    TextField("https://example.com/mcp", text: $server.url).keyboardType(.URL).textInputAutocapitalization(.never)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Section {
                    TextField("اسم الترويسة", text: $server.headerName).textInputAutocapitalization(.never)
                        .environment(\.layoutDirection, .leftToRight)
                    SecureField("القيمة، مثل: Bearer ghp_xxx", text: $header).textInputAutocapitalization(.never)
                        .environment(\.layoutDirection, .leftToRight)
                } header: { Text("المصادقة (اختياري)") } footer: {
                    Text("تُحفظ القيمة في Keychain. اتركها فارغة للخوادم العامة.")
                }
            }
            .navigationTitle(server.name.isEmpty ? "خادم جديد" : server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ واتصال") {
                        var s = server; s.enabled = true
                        mcp.upsert(s, header: header.isEmpty ? nil : header)
                        dismiss()
                    }
                    .disabled(server.name.isEmpty || URL(string: server.url)?.host == nil)
                }
            }
        }
    }
}

// MARK: - Memory & personalization

struct MemoryView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var items: [MemoryItem] = []
    @State private var newFact = ""

    var body: some View {
        Form {
            Section {
                Toggle("تفعيل الذاكرة", isOn: $settings.memoryEnabled)
            } footer: {
                Text("سَنَد يتذكر معلومات عنك عبر المحادثات (يحفظها الوكيل عندما تذكرها، أو تضيفها أنت). كل شيء محفوظ على جهازك.")
            }
            Section("تعليمات مخصصة") {
                TextEditor(text: $settings.customInstructions).frame(minHeight: 110)
                Text("مثال: أنا مطوّر من الرياض، جاوبني باختصار وبالأرقام، واستخدم اللهجة السعودية.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("الذكريات (\(items.count))") {
                HStack {
                    TextField("أضف معلومة…", text: $newFact)
                    Button("إضافة") { state.memory.add(newFact); newFact = ""; reload() }.disabled(newFact.isEmpty)
                }
                ForEach(items.reversed()) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.text)
                        Text(m.date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .swipeActions { Button(role: .destructive) { state.memory.remove(id: m.id); reload() } label: { Label("حذف", systemImage: "trash") } }
                }
                if !items.isEmpty {
                    Button("مسح كل الذكريات", role: .destructive) { state.memory.removeAll(); reload() }
                }
            }
        }
        .navigationTitle("الذاكرة والتخصيص")
        .onAppear(perform: reload)
    }

    func reload() { items = state.memory.all }
}
