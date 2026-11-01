import SwiftUI
import UniformTypeIdentifiers

/// One screen for everything model-related: what is installed, what is
/// downloading, curated picks, live Hugging Face discovery, and adding a model
/// by link or from Files. No separate hub screen, no dead ends.
struct ModelsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: AppSettings

    @State private var query = ""
    @State private var repos: [HFRepo] = []
    @State private var popular: [HFRepo] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var importing = false

    @State private var showLink = false
    @State private var link = ""
    @State private var linkError: String?
    @State private var parsed: HuggingFaceURL.Parsed?

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmed.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                if let e = models.lastError {
                    Section {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.footnote)
                    }
                }

                if isSearching {
                    localResults
                    onlineResults
                } else {
                    statusSection
                    downloadsSection
                    installedSection
                    catalogSection
                    popularSection
                    addSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("النماذج")
            .searchable(text: $query, prompt: "ابحث في نماذجك أو في Hugging Face")
            .navigationDestination(for: HFRepo.self) { repo in HFRepoView(repo: repo) }
            .onChange(of: query) { _, _ in scheduleSearch() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { importing = true } label: {
                            Label("استيراد GGUF من الملفات", systemImage: "square.and.arrow.down")
                        }
                        Button { showLink = true } label: {
                            Label("إضافة برابط Hugging Face", systemImage: "link")
                        }
                        Divider()
                        Button { Task { await loadPopular() } } label: {
                            Label("تحديث اكتشاف الإنترنت", systemImage: "arrow.clockwise")
                        }
                        if !models.inFlight.isEmpty {
                            Button(role: .destructive) { models.cleanPartialDownloads() } label: {
                                Label("إلغاء كل التحميلات", systemImage: "xmark.circle")
                            }
                        }
                        if state.engineReady {
                            Button { models.unload() } label: {
                                Label("إلغاء تحميل النموذج", systemImage: "eject")
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data, .data]) { result in
                if case .success(let url) = result {
                    do { try models.importModel(from: url) }
                    catch { models.lastError = error.localizedDescription }
                }
            }
            .sheet(isPresented: $showLink) { linkSheet }
            .task { if popular.isEmpty { await loadPopular() } }
        }
    }

    // MARK: Status

    @ViewBuilder var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: state.engineReady ? "bolt.horizontal.circle.fill" : "cpu")
                    .font(.title2)
                    .foregroundStyle(state.engineReady ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.engineReady ? (models.activeModel?.name ?? "نموذج محلي") : "لا يوجد نموذج محمّل")
                        .font(.headline)
                    Text(state.engineReady
                         ? "يعمل على الجهاز · \(RuntimeRegistry.summary)"
                         : "حمّل نموذجاً من الأسفل — كل شيء يعمل دون إنترنت بعد التحميل.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if models.isLoading { ProgressView() }
            }

            HStack {
                Label("ذاكرة الجهاز", systemImage: "memorychip")
                Spacer()
                Text(DeviceCapacity.summary).foregroundStyle(.secondary).font(.caption)
            }
            HStack {
                Label("سقف النموذج الآمن", systemImage: "gauge.with.dots.needle.33percent")
                Spacer()
                Text(DeviceCapacity.budgetDescription).foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    // MARK: Downloads

    @ViewBuilder var downloadsSection: some View {
        let items = models.inFlight
        if !items.isEmpty {
            Section("التحميلات") {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.model.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            if let failed = item.state.failed {
                                Text("فشل").font(.caption2).foregroundStyle(.red)
                            } else {
                                Text("\(Int(item.state.fraction * 100))%").font(.caption.monospacedDigit())
                            }
                        }
                        if let failed = item.state.failed {
                            Text(failed).font(.caption2).foregroundStyle(.red)
                        } else {
                            ProgressView(value: item.state.fraction)
                            HStack(spacing: 8) {
                                Text("\(item.state.received.fileSize) / \(item.state.total.fileSize)")
                                if item.state.bytesPerSecond > 0 {
                                    Text("· \(Int64(item.state.bytesPerSecond).fileSize)/ث")
                                }
                                Spacer()
                            }
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            if item.state.failed != nil || models.isPaused(item.model) {
                                Button("استئناف") { models.download(item.model) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            } else {
                                Button("إيقاف") { models.pause(item.model) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                            Button("إلغاء", role: .destructive) { models.cancel(item.model) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: Installed

    @ViewBuilder var installedSection: some View {
        Section("المثبّتة (\(models.installed.count))") {
            if models.installed.isEmpty {
                Text("لا نماذج مثبتة بعد. اختر من «مختارة لجهازك» أو ابحث في Hugging Face.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(models.installed) { model in
                InstalledModelRow(model: model)
            }
        }
    }

    // MARK: Curated catalog

    @ViewBuilder var catalogSection: some View {
        let rec = ModelCatalog.recommended(forMemory: ModelManager.physicalMemory)
        Section {
            ForEach(ModelCatalog.models) { m in
                CatalogRow(model: m, recommended: m.id == rec.id)
            }
        } header: {
            Text("مختارة لجهازك")
        } footer: {
            Text("موصى به لجهازك (\(Int64(ModelManager.physicalMemory).fileSize)): \(rec.name). الأحجام تقريبية والسرعة تعتمد على المعالج.")
                .font(.caption2)
        }
    }

    // MARK: Hugging Face

    @ViewBuilder var popularSection: some View {
        Section {
            if popular.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("أقرأ الأكثر تنزيلاً من Hugging Face…").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                ForEach(popular.prefix(8)) { repo in
                    NavigationLink(value: repo) { HFRepoRow(repo: repo) }
                }
            }
        } header: {
            HStack {
                Text("على Hugging Face")
                Spacer()
                Text("بحث الإنترنت").font(.caption2).foregroundStyle(.secondary)
            }
        } footer: {
            Text("اكتب في البحث أعلاه للوصول إلى آلاف النماذج، ثم اختر ملف GGUF يناسب ذاكرة جهازك.")
                .font(.caption2)
        }
    }

    @ViewBuilder var localResults: some View {
        let matches = localMatches
        if !matches.isEmpty {
            Section("في جهازك ومكتبتك") {
                ForEach(matches) { m in
                    if models.isInstalled(m) {
                        InstalledModelRow(model: m)
                    } else {
                        CatalogRow(model: m, recommended: false)
                    }
                }
            }
        }
    }

    @ViewBuilder var onlineResults: some View {
        Section {
            if searching && repos.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("أبحث في Hugging Face…").font(.footnote) }
            } else if let searchError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(searchError).font(.footnote).foregroundStyle(.secondary)
                    Button("أعد البحث") { scheduleSearch(immediate: true) }.font(.footnote)
                }
            } else if repos.isEmpty {
                Text("لا نتائج لهذا البحث.").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(repos) { repo in
                    NavigationLink(value: repo) { HFRepoRow(repo: repo) }
                }
            }
        } header: {
            Text("Hugging Face")
        } footer: {
            if !repos.isEmpty {
                Text("\(repos.count) مستودع. افتح المستودع لاختيار الملف والقياس.")
                    .font(.caption2)
            }
        }
    }

    var localMatches: [ModelInfo] {
        let q = ArabicText.normalize(trimmed)
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        var list: [ModelInfo] = []
        for m in models.installed + ModelCatalog.models {
            guard seen.insert(m.fileName).inserted else { continue }
            if ArabicText.normalize(m.name).contains(q) || ArabicText.normalize(m.publisher).contains(q) {
                list.append(m)
            }
        }
        return list
    }

    // MARK: Add by link

    @ViewBuilder var addSection: some View {
        Section {
            Button { showLink = true } label: {
                Label("إضافة نموذج برابط Hugging Face", systemImage: "link.badge.plus")
            }
            Button { importing = true } label: {
                Label("استيراد ملف GGUF من الملفات", systemImage: "doc.badge.plus")
            }
        } header: {
            Text("أضف نموذجاً")
        } footer: {
            Text("المدعوم: GGUF عبر llama.cpp. ملفات MLX وملفات الرؤية mmproj غير مدعومة في هذه النسخة.")
                .font(.caption2)
        }
    }

    var linkSheet: some View {
        NavigationStack {
            Form {
                Section("رابط النموذج") {
                    TextField("https://huggingface.co/owner/repo/blob/main/model.gguf", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    Button("تحليل الرابط") { analyzeLink() }
                }

                if let p = parsed {
                    Section("النتيجة") {
                        LabeledContent("المستودع", value: p.repo)
                        LabeledContent("الملف", value: p.file.isEmpty ? "اختر من المستودع" : p.file)
                        if p.file.isEmpty {
                            Text("هذا رابط مستودع. حمّل ملفاً منه مباشرة من الأسفل.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            let format = ModelFormat.detect(fileName: p.file)
                            LabeledContent("المحرك", value: format.title)
                            LabeledContent("الحالة", value: RuntimeRegistry.availability(for: format).isAvailable ? "مدعوم" : "غير مدعوم")
                        }
                    }
                    if p.file.isEmpty {
                        NavigationLink {
                            HFRepoView(repo: HFRepo(id: p.repo, downloads: 0, likes: 0, tags: [], updated: nil),
                                       onDownload: { showLink = false })
                        } label: {
                            Label("افتح ملفات المستودع", systemImage: "folder")
                        }
                    } else if RuntimeRegistry.availability(for: ModelFormat.detect(fileName: p.file)).isAvailable {
                        Button("تحميل") { download(p) }
                    }
                }

                if let linkError {
                    Section { Text(linkError).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("إضافة برابط")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { showLink = false } }
            }
        }
    }

    func analyzeLink() {
        linkError = nil
        guard let p = HuggingFaceURL.parse(link) else {
            parsed = nil
            linkError = "لم أتعرف على الرابط. الصيغ: owner/repo/file.gguf أو رابط resolve أو رابط مستودع."
            return
        }
        parsed = p
    }

    func download(_ p: HuggingFaceURL.Parsed) {
        let fileName = (p.file as NSString).lastPathComponent
        let info = ModelInfo(id: "hf-" + UUID().uuidString,
                             name: (fileName as NSString).deletingPathExtension,
                             publisher: p.repo,
                             summary: "نموذج مضاف من Hugging Face",
                             repo: p.repo, file: fileName,
                             sizeBytes: 0, parameters: "—", contextLength: 4096,
                             badges: [], license: "—", isLocalImport: true,
                             remotePath: p.file)
        models.register(info)
        models.download(info)
        showLink = false
        link = ""
        parsed = nil
    }

    // MARK: Search

    func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        let q = trimmed
        guard !q.isEmpty else {
            repos = []; searchError = nil; searching = false
            return
        }
        searching = true
        searchError = nil
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 450_000_000)
                if Task.isCancelled { return }
            }
            do {
                let results = try await HuggingFaceHub.search(q, limit: 24)
                if Task.isCancelled { return }
                repos = results
                if results.isEmpty { searchError = "لا نتائج في Hugging Face." }
            } catch {
                if !Task.isCancelled { searchError = error.localizedDescription }
            }
            if !Task.isCancelled { searching = false }
        }
    }

    func loadPopular() async {
        do {
            let results = try await HuggingFaceHub.search("", limit: 14)
            if !results.isEmpty { popular = results }
        } catch {
            // Discovery is optional; the catalog still works offline.
        }
    }
}

// MARK: - Rows

struct InstalledModelRow: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: AppSettings
    let model: ModelInfo

    var isActive: Bool { models.activeModelID == model.id && state.engineReady }

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink {
                ModelDetailView(ref: model.id, displayName: model.name)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name).font(.headline)
                    Text("\(model.publisher) · \(model.sizeBytes.fileSize)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if models.isLoading {
                ProgressView()
            } else {
                Button("تشغيل") {
                    Task { await models.load(model, contextLength: settings.generation.contextLength) }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .swipeActions {
            Button(role: .destructive) { models.delete(model) } label: { Label("حذف", systemImage: "trash") }
        }
    }
}

struct CatalogRow: View {
    @EnvironmentObject var models: ModelManager
    let model: ModelInfo
    let recommended: Bool

    var fits: Bool { ModelCatalog.fits(model, memory: ModelManager.physicalMemory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name).font(.headline)
                        if recommended { Image(systemName: "star.fill").foregroundStyle(Color("Gold")).font(.caption) }
                    }
                    Text("\(model.publisher) · \(model.parameters) · \(model.sizeBytes.fileSize)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                action
            }
            Text(model.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            if !fits {
                Label("قد لا تكفي ذاكرة جهازك لهذا النموذج", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let d = models.downloads[model.id] {
                ProgressView(value: d.fraction)
                Text("\(Int(d.fraction * 100))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder var action: some View {
        if models.isInstalled(model) {
            Label("مثبّت", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        } else if let d = models.downloads[model.id], d.failed == nil, !models.isPaused(model) {
            Text("\(Int(d.fraction * 100))%").font(.caption.monospacedDigit().bold())
        } else if models.isPaused(model) || models.downloads[model.id]?.failed != nil {
            Button("استئناف") { models.download(model) }.buttonStyle(.bordered).controlSize(.small)
        } else {
            Button { models.download(model) } label: { Label("تحميل", systemImage: "arrow.down.circle") }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }
}
