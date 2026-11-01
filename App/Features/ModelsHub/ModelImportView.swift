import SwiftUI

/// Adds a model by Hugging Face URL, with an honest compatibility verdict before downloading.
struct ModelImportView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var parsed: HuggingFaceURL.Parsed?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("رابط النموذج") {
                    TextField("https://huggingface.co/owner/repo/resolve/main/model.gguf", text: $input, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    Button("تحليل الرابط") { analyze() }
                }

                if let p = parsed {
                    Section("المتاح") {
                        LabeledContent("المستودع", value: p.repo)
                        LabeledContent("الملف", value: p.file.isEmpty ? "—" : p.file)
                        LabeledContent("المحرك", value: ModelFormat.detect(fileName: p.file).title)
                        let verdict = RuntimeRegistry.availability(for: ModelFormat.detect(fileName: p.file))
                        LabeledContent("الحالة", value: verdict.isAvailable ? "مدعوم" : "غير مدعوم")
                        if let reason = verdict.reason {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("سيُحمَّل إلى مجلد النماذج ويُستأنَف إن انقطع الاتصال.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button("تحميل") { download(p) }
                            .disabled(!RuntimeRegistry.availability(for: ModelFormat.detect(fileName: p.file)).isAvailable)
                    }
                }

                Section {
                    Text("لا يمكن إضافة نموذج MLX في هذه النسخة لأن حزمة MLX غير مضمّنة في البناء. المدعوم: GGUF عبر llama.cpp.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("إضافة نموذج")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
            }
        }
    }

    func analyze() {
        error = nil
        guard let p = HuggingFaceURL.parse(input) else {
            parsed = nil
            error = "لم أتعرف على الرابط. الصيغ المقبولة: owner/repo/file.gguf أو رابط resolve كامل."
            return
        }
        guard !p.file.isEmpty else {
            parsed = nil
            error = "أضف مسار الملف داخل المستودع (ينتهي بـ .gguf)."
            return
        }
        parsed = p
    }

    func download(_ p: HuggingFaceURL.Parsed) {
        guard let url = HuggingFaceURL.downloadURL(repo: p.repo, file: p.file) else { return }
        let name = (p.file as NSString).lastPathComponent
        let info = ModelInfo(id: "hf-" + UUID().uuidString,
                             name: (name as NSString).deletingPathExtension,
                             publisher: p.repo,
                             summary: "نموذج مضاف من Hugging Face",
                             repo: p.repo, file: name,
                             sizeBytes: 0, parameters: "—", contextLength: 4096,
                             badges: [], license: "—", isLocalImport: true)
        _ = url
        models.register(info)
        models.download(info)
        dismiss()
    }
}
