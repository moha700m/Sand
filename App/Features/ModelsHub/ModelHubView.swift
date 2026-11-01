import SwiftUI

/// Compact row used by the merged model search / discovery sections.
struct HFRepoRow: View {
    let repo: HFRepo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(repo.id).font(.footnote.weight(.semibold)).lineLimit(1)
            HStack(spacing: 10) {
                Label("\(repo.downloads)", systemImage: "arrow.down.circle")
                Label("\(repo.likes)", systemImage: "heart")
                if let u = repo.updated { Text(String(u.prefix(10))) }
                Spacer()
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Files inside one Hugging Face repo, with a real fit verdict per file.
struct HFRepoView: View {
    @EnvironmentObject var models: ModelManager
    let repo: HFRepo
    var onDownload: (() -> Void)? = nil

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
                    Text("لا ملفات GGUF قابلة للتحميل في هذا المستودع.")
                        .font(.footnote).foregroundStyle(.secondary)
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
                            Text(f.isProjector ? "مُسقط رؤية (mmproj) — يحتاج محرك رؤية غير مضمّن."
                                               : "ملف مجزّأ — التحميل لا يجمع الأجزاء بعد.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let queued {
                Section {
                    Label("بدأ تحميل \(queued) — تابع التقدم من تبويب النماذج.",
                          systemImage: "arrow.down.circle.fill")
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
                    let verdict = DeviceCapacity.verdict(forWeights: file.size)
                    Label(verdict.title, systemImage: verdict.icon)
                        .foregroundStyle(color(for: verdict))
                }
            }
            .font(.caption2).foregroundStyle(.secondary)

            Button { download(file) } label: {
                Label("تحميل", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    func color(for verdict: FitVerdict) -> Color {
        switch verdict {
        case .fits: return .green
        case .tight: return .orange
        case .tooBig: return .red
        case .unknown: return .secondary
        }
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
        onDownload?()
    }
}
