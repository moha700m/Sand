import SwiftUI

/// Browse the whole Hugging Face GGUF catalog, pick a quantization, download it.
struct ModelHubView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var repos: [HFRepo] = []
    @State private var loading = false
    @State private var error: String?
    @State private var hasSearched = false

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                if loading && repos.isEmpty {
                    Section { HStack { ProgressView(); Text("أبحث في Hugging Face…").font(.footnote) } }
                }
                Section {
                    ForEach(repos) { repo in
                        NavigationLink {
                            HFRepoView(repo: repo)
                        } label: { row(repo) }
                    }
                } header: {
                    Text(hasSearched ? "النتائج (\(repos.count))" : "الأكثر تنزيلاً")
                } footer: {
                    Text("البحث يغطي مستودعات GGUF فقط. اختر المستودع ثم ملف القياس المناسب لجهازك.")
                        .font(.caption2)
                }
            }
            .searchable(text: $query, prompt: "qwen3 · gemma · llama · arabic")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationTitle("مكتبة النماذج")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await search() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading)
                }
            }
            .task { if !hasSearched { await search() } }
        }
    }

    func row(_ repo: HFRepo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(repo.id).font(.footnote.weight(.semibold)).lineLimit(1)
            HStack(spacing: 10) {
                Label("\(repo.downloads)", systemImage: "arrow.down.circle").font(.caption2)
                Label("\(repo.likes)", systemImage: "heart").font(.caption2)
                if let u = repo.updated { Text(String(u.prefix(10))).font(.caption2) }
            }
            .foregroundStyle(.secondary)
        }
    }

    func search() async {
        loading = true
        error = nil
        defer { loading = false; hasSearched = true }
        do {
            repos = try await HuggingFaceHub.search(query)
            if repos.isEmpty { error = "لا نتائج لهذا البحث." }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct HFRepoView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    let repo: HFRepo

    @State private var files: [HFFile] = []
    @State private var loading = false
    @State private var error: String?
    @State private var queued: String?

    var downloadable: [HFFile] { files.filter { !$0.isProjector && !$0.isSplit } }
    var skipped: [HFFile] { files.filter { $0.isProjector || $0.isSplit } }

    var body: some View {
        List {
            Section("المستودع") {
                Text(repo.id).font(.footnote.monospaced()).textSelection(.enabled)
                LabeledContent("تنزيلات", value: "\(repo.downloads)")
                LabeledContent("إعجابات", value: "\(repo.likes)")
            }

            if loading && files.isEmpty {
                Section { HStack { ProgressView(); Text("أقرأ الملفات…").font(.footnote) } }
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }

            Section("ملفات GGUF (\(downloadable.count))") {
                if !loading && downloadable.isEmpty {
                    Text("لا ملفات GGUF قابلة للتحميل في هذا المستودع.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(downloadable) { file in
                    fileRow(file)
                }
            }

            if !skipped.isEmpty {
                Section("ملفات غير مدعومة") {
                    ForEach(skipped) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.fileName).font(.caption).lineLimit(1)
                            Text(f.isProjector ? "مُسقط رؤية (mmproj) — يحتاج محرك رؤية غير مضمّن." : "ملف مجزّأ — التحميل لا يجمع الأجزاء بعد.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let queued {
                Section {
                    Label("بدأ تحميل \(queued) — تابع التقدم من تبويب النماذج.", systemImage: "arrow.down.circle.fill")
                        .font(.footnote).foregroundStyle(.green)
                }
            }
        }
        .navigationTitle(repo.id.split(separator: "/").last.map(String.init) ?? repo.id)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    func fileRow(_ file: HFFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(file.fileName).font(.caption.weight(.semibold)).lineLimit(1)
            HStack(spacing: 8) {
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                Text(HuggingFaceHub.quantization(of: file.fileName))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                if file.size > 0 {
                    let need = Int64(Double(file.size) * 1.2) + 350_000_000
                    if Double(need) > Double(ModelManager.physicalMemory) * 0.65 {
                        Text("أكبر من ذاكرة جهازك").foregroundStyle(.orange)
                    }
                }
            }
            .font(.caption2).foregroundStyle(.secondary)

            Button {
                download(file)
            } label: {
                Label("تحميل", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    func load() async {
        loading = true
        defer { loading = false }
        do { files = try await HuggingFaceHub.files(repo: repo.id) }
        catch { self.error = error.localizedDescription }
    }

    func download(_ file: HFFile) {
        let name = (file.fileName as NSString).deletingPathExtension
        let info = ModelInfo(id: "hf-" + UUID().uuidString,
                             name: name,
                             publisher: repo.id,
                             summary: "نموذج من Hugging Face",
                             repo: repo.id,
                             file: file.fileName,
                             sizeBytes: file.size,
                             parameters: "—",
                             contextLength: 4096,
                             badges: [],
                             license: "—",
                             isLocalImport: true,
                             kind: .chat,
                             remotePath: file.path)
        models.register(info)
        models.download(info)
        queued = file.fileName
    }
}
