import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// "الزبدة": turn an exported chat into decisions, tasks and dates.
/// Runs on the active model; the file never leaves the device when local.
struct ChatSummaryView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var engine = ChatBriefing()

    var onClose: (() -> Void)? = nil

    @State private var archive: ChatArchive?
    @State private var fileName = ""
    @State private var importing = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if let archive {
                    stats(archive)
                    action(archive)
                } else {
                    importCard
                }

                if engine.isRunning { progressCard }
                if !engine.brief.isEmpty { resultCard }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(Theme.screenPad)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("الزبدة")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { onClose?() }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text]) { result in
            switch result {
            case .success(let url): load(url)
            case .failure(let e): error = e.localizedDescription
            }
        }
        .onDisappear { task?.cancel() }
    }

    // MARK: Header

    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                IconTile(icon: "text.bubble.fill", color: .teal, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("الزبدة").font(.title2.bold())
                    Text("خلاصة أي محادثة: القرارات، المهام، والمواعيد.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Label(state.isCloud(nil) ? "سيُرسل نص المحادثة إلى المزود السحابي المحدد."
                                     : "كل التحليل على جهازك — الملف لا يغادر الآيفون.",
                  systemImage: state.isCloud(nil) ? "cloud.fill" : "lock.fill")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Import

    var importCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Button { importing = true } label: {
                    Label("اختر ملف المحادثة (.txt)", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 4) {
                    Text("من واتساب: افتح المحادثة ← مشاركة ← حفظ في الملفات.")
                        .font(.caption)
                    Text("يدعم تصدير iOS وAndroid، والأرقام العربية، والرسائل المتعددة الأسطر.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Stats

    func stats(_ archive: ChatArchive) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(fileName).font(.footnote.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button("تغيير") { importing = true }.font(.caption)
                }

                HStack(spacing: 8) {
                    metric("\(archive.messageCount)", "رسالة")
                    metric("\(archive.participantCount)", "مشارك")
                    metric(range(archive), "الفترة")
                }

                if !archive.topSenders.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(archive.topSenders, id: \.name) { s in
                                Text("\(s.name) · \(s.count)")
                                    .font(.caption2)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.primary.opacity(0.05), in: Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    func metric(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    func range(_ archive: ChatArchive) -> String {
        guard let first = archive.firstDate, let last = archive.lastDate else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar_SA")
        f.dateFormat = "d MMM"
        return "\(f.string(from: first)) – \(f.string(from: last))"
    }

    // MARK: Run

    func action(_ archive: ChatArchive) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { run(archive) } label: {
                Label(engine.isRunning ? "جاري التحليل…" : "استخرج الزبدة", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(engine.isRunning)

            if archive.messageCount > ChatBriefing.maxMessages {
                Text("سنحلل آخر \(ChatBriefing.maxMessages) رسالة للحفاظ على السرعة.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    var progressCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(engine.status).font(.footnote)
                }
                ProgressView(value: engine.progress)
            }
        }
    }

    var resultCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("الزبدة", systemImage: "checkmark.seal.fill")
                        .font(.headline).foregroundStyle(.green)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = engine.brief
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    ShareLink(item: engine.brief) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .font(.footnote)

                MarkdownText(text: engine.brief)

                Button("تحليل محادثة أخرى") {
                    engine.reset()
                    archive = nil
                    fileName = ""
                }
                .font(.footnote)
            }
        }
    }

    // MARK: Logic

    func load(_ url: URL) {
        error = nil
        engine.reset()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16)
                    ?? String(data: data, encoding: .isoLatin1) else {
                error = "تعذّر قراءة الملف كنص."
                return
            }
            let parsed = ChatArchiveParser.parse(text, title: url.deletingPathExtension().lastPathComponent)
            guard parsed.messageCount >= 3 else {
                error = "هذا الملف لا يبدو تصدير محادثة واتساب. صدّر المحادثة من واتساب كملف نصي."
                return
            }
            archive = parsed
            fileName = url.lastPathComponent
        } catch {
            self.error = error.localizedDescription
        }
    }

    func run(_ archive: ChatArchive) {
        guard state.isReady(nil) else {
            error = "حمّل نموذجاً محلياً أو اضبط مزوداً سحابياً أولاً."
            return
        }
        error = nil
        task?.cancel()
        task = Task {
            do {
                _ = try await engine.run(messages: archive.messages, backend: state.backend(for: nil))
            } catch is CancellationError {
                // Leaving the screen cancels quietly.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
