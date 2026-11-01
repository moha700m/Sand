import PhotosUI
import SwiftUI

struct LensView: View {
    @EnvironmentObject var state: AppState
    @State private var image: UIImage?
    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var busy = false
    @State private var result = ""
    @State private var mode: Mode = .explain
    @State private var error: String?

    enum Mode: String, CaseIterable, Identifiable {
        case explain, translate, summarize, solve, code
        var id: String { rawValue }
        var title: String {
            switch self {
            case .explain: return "اشرح"
            case .translate: return "ترجم"
            case .summarize: return "لخّص"
            case .solve: return "حل"
            case .code: return "راجع الكود"
            }
        }
        var icon: String {
            switch self {
            case .explain: return "text.bubble"
            case .translate: return "character.bubble"
            case .summarize: return "list.bullet.rectangle"
            case .solve: return "function"
            case .code: return "ladybug"
            }
        }
        func prompt(_ t: String) -> String {
            switch self {
            case .explain: return "هذا نص من صورة. اشرحه بوضوح وبإيجاز بالعربية:\n\n\(t)"
            case .translate: return "ترجم النص التالي: إذا كان عربياً فإلى الإنجليزية، وإذا كان بلغة أخرى فإلى العربية. أعطِ الترجمة فقط.\n\n\(t)"
            case .summarize: return "لخّص النص التالي في نقاط قصيرة بالعربية:\n\n\(t)"
            case .solve: return "حل المسألة التالية خطوة بخطوة، ثم اكتب الإجابة النهائية بوضوح:\n\n\(t)"
            case .code: return "Review this code extracted from a photo. List bugs, security issues and improvements, then give a fixed version. Explain in Arabic.\n\n```\n\(t)\n```"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    imageArea
                    HStack(spacing: 12) {
                        Button { showCamera = true } label: { Label("الكاميرا", systemImage: "camera.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("الصور", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)

                    if !text.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("النص المستخرج (قابل للتعديل)", systemImage: "text.viewfinder").font(.headline)
                                TextEditor(text: $text).frame(minHeight: 120).scrollContentBackground(.hidden)
                            }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(Mode.allCases) { m in
                                    Button { mode = m; ask() } label: { Label(m.title, systemImage: m.icon) }
                                        .buttonStyle(.bordered)
                                        .tint(mode == m ? Color.accentColor : .gray)
                                }
                                Button { SpeechService.shared.speak(text) } label: { Label("اقرأ بصوت", systemImage: "speaker.wave.2") }
                                    .buttonStyle(.bordered)
                                Button {
                                    state.knowledge.add(title: "صورة \(Date().formatted(date: .abbreviated, time: .shortened))", text: text)
                                    result = "تم حفظ النص في قاعدة المعرفة."
                                } label: { Label("احفظ للمعرفة", systemImage: "books.vertical") }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    if busy { ProgressView("يفكر…") }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    if !result.isEmpty { Card { MarkdownText(text: result) } }
                }
                .padding()
            }
            .navigationTitle("العدسة")
            .safeAreaInset(edge: .top) { if !text.isEmpty { ModelStatusBanner() } }
            .onChange(of: photoItem) { _, item in
                Task {
                    if let d = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: d) { await process(img) }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { img in Task { await process(img) } }.ignoresSafeArea()
            }
        }
    }

    @ViewBuilder var imageArea: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            VStack(spacing: 10) {
                Image(systemName: "camera.viewfinder").font(.system(size: 54)).foregroundStyle(.tint)
                Text("صوّر أي نص، فاتورة، مسألة أو كود").font(.headline)
                Text("القراءة (OCR) تتم على جهازك وتدعم العربية والإنجليزية، ثم يشرح أو يترجم أو يحل النموذج المحلي.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(28)
            .background(Color("CardBackground"), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    func process(_ img: UIImage) async {
        image = img
        result = ""; error = nil
        busy = true
        do {
            text = try await OCRService.recognize(img)
            state.lastImageText = text
            if text.isEmpty { error = "لم يُعثر على نص في الصورة." }
        } catch { self.error = error.localizedDescription }
        busy = false
    }

    func ask() {
        guard state.engineReady else { error = LLMError.noModelLoaded.localizedDescription; return }
        busy = true; result = ""; error = nil
        let msgs = [ChatMessage(role: .system, content: Persona.general.systemPrompt), ChatMessage(role: .user, content: mode.prompt(text))]
        var settings = state.settings.generation
        settings.temperature = 0.3
        let s = settings
        Task {
            var acc = ""
            do {
                let (out, _) = try await state.backend(for: nil).generate(messages: msgs, settings: s, stop: []) { piece in
                    acc += piece
                    let shown = ThinkingFilter.strip(acc)
                    Task { @MainActor in result = shown }
                    return true
                }
                result = ThinkingFilter.strip(out)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
