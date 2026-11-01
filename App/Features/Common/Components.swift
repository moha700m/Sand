import SwiftUI
import WebKit

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color("CardBackground"), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct BadgeView: View {
    let badge: ModelBadge
    var body: some View {
        Label(badge.title, systemImage: badge.icon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
    var color: Color {
        switch badge {
        case .saudi: return Color("AccentColor")
        case .recommended: return Color("Gold")
        case .arabic: return .teal
        case .fast: return .orange
        case .tools: return .indigo
        case .coder: return .purple
        case .thinking: return .pink
        case .multilingual: return .blue
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 48)).foregroundStyle(.tint)
            Text(title).font(.title3.bold())
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.borderedProminent).padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// Banner shown when no model is loaded.
struct ModelStatusBanner: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager

    var body: some View {
        if models.isLoading {
            HStack { ProgressView(); Text("جاري تحميل النموذج في الذاكرة…").font(.footnote) }
                .padding(10).frame(maxWidth: .infinity).background(.thinMaterial)
        } else if !state.engineReady && !UserDefaults.standard.bool(forKey: "demo") {
            Button { state.tab = .models } label: {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(models.installed.isEmpty ? "لا يوجد نموذج — اضغط لتحميل نموذج" : "اختر نموذجاً لتشغيله")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.left")
                }
                .padding(10)
                .background(.orange.opacity(0.12))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Lightweight markdown renderer: paragraphs with inline markdown plus fenced code blocks.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                if seg.isCode {
                    CodeBlock(code: seg.text, language: seg.language)
                } else {
                    Text(attributed(seg.text)).textSelection(.enabled)
                }
            }
        }
    }

    struct Segment { var text: String; var isCode: Bool; var language: String }

    var segments: [Segment] {
        var out: [Segment] = []
        let parts = text.components(separatedBy: "```")
        for (i, p) in parts.enumerated() {
            if i % 2 == 1 {
                var lines = p.components(separatedBy: "\n")
                let lang = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
                if !lines.isEmpty { lines.removeFirst() }
                out.append(Segment(text: lines.joined(separator: "\n").trimmingCharacters(in: .newlines), isCode: true, language: lang))
            } else {
                let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(Segment(text: t, isCode: false, language: "")) }
            }
        }
        return out
    }

    func attributed(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

struct CodeBlock: View {
    let code: String
    let language: String
    @State private var copied = false
    @State private var preview = false

    var previewable: Bool {
        let l = language.lowercased()
        return l == "html" || l == "svg" || l == "xml" && code.contains("<svg") || code.lowercased().hasPrefix("<!doctype html")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if previewable {
                    Button { preview = true } label: { Label("معاينة", systemImage: "play.rectangle").font(.caption2.bold()) }
                        .padding(.trailing, 8)
                }
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "تم النسخ" : "نسخ", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption2)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .padding(10)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $preview) { ArtifactView(html: code, isSVG: language.lowercased() == "svg") }
    }
}

/// Live preview of HTML/SVG the model wrote (like Claude Artifacts / ChatGPT Canvas).
struct ArtifactView: View {
    let html: String
    var isSVG = false
    @Environment(\.dismiss) var dismiss
    @State private var showCode = false

    var page: String {
        if isSVG || !html.lowercased().contains("<html") {
            return "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body style='margin:0;font-family:-apple-system'>\(html)</body></html>"
        }
        return html
    }

    var body: some View {
        NavigationStack {
            Group {
                if showCode {
                    ScrollView { Text(html).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding() }
                        .environment(\.layoutDirection, .leftToRight)
                } else {
                    WebView(html: page).ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle("معاينة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    HStack {
                        Button { showCode.toggle() } label: { Image(systemName: showCode ? "eye" : "chevron.left.forwardslash.chevron.right") }
                        ShareLink(item: html) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) { w.loadHTMLString(html, baseURL: nil) }
}

extension Int64 {
    var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
