import Network
import SwiftUI

struct ServerView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var running = false
    @State private var logs: [String] = []
    @State private var key = Keychain.get("apiKey") ?? ""
    @State private var error: String?
    @State private var ip = "…"

    var base: String { "http://\(ip):\(settings.serverPort)" }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { running }, set: { $0 ? start() : stop() })) {
                    Label("تشغيل الخادم", systemImage: "server.rack")
                }
                Stepper("المنفذ: \(settings.serverPort)", value: $settings.serverPort, in: 1024...65000, step: 1)
                    .disabled(running)
                LabeledContent("العنوان", value: base).textSelection(.enabled)
                LabeledContent("النموذج", value: state.models.activeModel?.name ?? "لا يوجد")
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            } footer: {
                Text("متوافق مع OpenAI و Ollama. للاستخدام على شبكة موثوقة فقط وأثناء فتح التطبيق.")
            }
            Section("مفتاح API") {
                Text(key.isEmpty ? "بدون مفتاح (أي جهاز على الشبكة يمكنه الاتصال)" : key)
                    .font(.caption.monospaced()).textSelection(.enabled)
                Button(key.isEmpty ? "إنشاء مفتاح" : "تدوير المفتاح") {
                    key = Keychain.randomKey(); Keychain.set(key, for: "apiKey")
                }
                if !key.isEmpty { Button("إزالة المفتاح", role: .destructive) { Keychain.delete("apiKey"); key = "" } }
            }
            Section("مثال") {
                Text("""
                curl \(base)/v1/chat/completions \\
                  -H "Authorization: Bearer \(key.isEmpty ? "none" : key)" \\
                  -H "Content-Type: application/json" \\
                  -d '{"model":"sanad","messages":[{"role":"user","content":"مرحبا"}]}'
                """)
                .font(.caption2.monospaced()).textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
                Text("Ollama: \(base)/api/chat · \(base)/api/tags\nOpenAI: \(base)/v1 (models, chat/completions)")
                    .font(.caption2.monospaced()).environment(\.layoutDirection, .leftToRight)
            }
            if !logs.isEmpty {
                Section("السجل") {
                    ForEach(Array(logs.suffix(30).enumerated().reversed()), id: \.offset) { _, l in
                        Text(l).font(.caption2.monospaced())
                    }
                }
            }
        }
        .navigationTitle("خادم API المحلي")
        .onAppear {
            running = state.server.isRunning
            ip = Self.localIP() ?? "127.0.0.1"
            state.server.onLog = { l in logs.append(l) }
            state.server.onStateChange = { r in running = r }
        }
    }

    func start() {
        error = nil
        if !state.engineReady { error = "حمّل نموذجاً أولاً من تبويب النماذج." }
        do { try state.server.start(port: UInt16(settings.serverPort)); running = true } catch { self.error = error.localizedDescription }
    }

    func stop() { state.server.stop(); running = false }

    static func localIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name == "en0" || name.hasPrefix("bridge") || name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: host)
            if name == "en0" { break }
        }
        return address
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var gen = GenerationSettings()
    @State private var confirmWipe = false

    var body: some View {
        Form {
            Section("التوليد") {
                Picker("الشخصية الافتراضية", selection: $settings.personaID) {
                    ForEach(Persona.all) { Text($0.name).tag($0.id) }
                }
                VStack(alignment: .leading) {
                    Text("الإبداع (Temperature): \(gen.temperature, specifier: "%.2f")")
                    Slider(value: $gen.temperature, in: 0...1.5, step: 0.05)
                }
                VStack(alignment: .leading) {
                    Text("Top-P: \(gen.topP, specifier: "%.2f")")
                    Slider(value: $gen.topP, in: 0.1...1, step: 0.05)
                }
                Stepper("أقصى طول للرد: \(gen.maxTokens)", value: $gen.maxTokens, in: 128...4096, step: 128)
                Picker("طول السياق", selection: $gen.contextLength) {
                    ForEach([2048, 4096, 8192, 16384], id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("وضع التفكير (Qwen3)", isOn: $gen.enableThinking)
                Toggle("إخفاء خطوات التفكير", isOn: $gen.hideThinking)
            }
            Section("الوكلاء") {
                Stepper("أقصى خطوات للوكيل: \(settings.agentMaxSteps)", value: $settings.agentMaxSteps, in: 2...12)
                Toggle(isOn: $settings.webAccess) {
                    VStack(alignment: .leading) {
                        Text("السماح بالبحث في الويب")
                        Text("معطّل افتراضياً. عند التفعيل تُرسل عبارة البحث إلى DuckDuckGo.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("الصوت") {
                Toggle("قراءة الردود تلقائياً", isOn: $settings.speakReplies)
            }
            Section("المظهر") {
                Picker("الوضع", selection: $settings.appearance) {
                    Text("تلقائي").tag(0); Text("فاتح").tag(1); Text("داكن").tag(2)
                }
                Picker("اللون", selection: $settings.accent) {
                    ForEach(Array(AppSettings.accents.enumerated()), id: \.offset) { i, a in
                        Label { Text(a.0) } icon: { Circle().fill(a.1).frame(width: 14, height: 14) }.tag(i)
                    }
                }
            }
            Section("الذاكرة") {
                Toggle("تجاوز فحص الذاكرة (قد يُغلق التطبيق)", isOn: $settings.ignoreMemoryCheck)
                LabeledContent("ذاكرة الجهاز", value: Int64(ModelManager.physicalMemory).fileSize)
            }
            Section {
                Button("مسح كل البيانات", role: .destructive) { confirmWipe = true }
            } header: { Text("الخصوصية") } footer: {
                Text("يحذف المحادثات والمستندات والملاحظات والوكلاء المخصصين والمفاتيح. النماذج المحمّلة تبقى ويمكن حذفها من تبويب النماذج.")
            }
            Section("حول") {
                LabeledContent("الإصدار", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                LabeledContent("المحرك", value: "llama.cpp (GGUF · Metal)")
            }
        }
        .navigationTitle("الإعدادات")
        .onAppear { gen = settings.generation }
        .onChange(of: gen) { _, v in settings.generation = v }
        .confirmationDialog("سيتم حذف كل بياناتك نهائياً.", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("مسح الكل", role: .destructive) { state.wipeAllData() }
        }
    }
}

struct OnboardingView: View {
    var done: () -> Void
    @State private var page = 0

    let pages: [(String, String, String)] = [
        ("sparkles", "أهلاً بك في سَنَد", "ذكاء اصطناعي يعمل على جهازك بالكامل. محادثاتك ومستنداتك لا تغادر الآيفون."),
        ("wand.and.stars", "وكلاء ينفّذون عنك", "الوكيل يخطط ويستخدم الأدوات خطوة بخطوة: تذكيرات، مواعيد، مستنداتك، حسابات دقيقة — وبموافقتك."),
        ("star.circle", "بهوية سعودية", "التقويم الهجري (أم القرى)، مواقيت الصلاة، الزكاة، ضريبة 15%، نهاية الخدمة، ونموذج ALLaM السعودي."),
        ("cpu", "اختر نموذجك", "حمّل نموذجاً مرة واحدة واستخدمه بدون إنترنت. ننصح بالبدء بـ Qwen3 1.7B."),
    ]

    var body: some View {
        VStack {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                    VStack(spacing: 20) {
                        Image(systemName: p.0).font(.system(size: 72)).foregroundStyle(Color("Gold"))
                        Text(p.1).font(.largeTitle.bold()).multilineTextAlignment(.center)
                        Text(p.2).font(.title3).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(32)
                    .tag(i)
                }
            }
            .tabViewStyle(.page)
            Button {
                if page < pages.count - 1 { withAnimation { page += 1 } } else { done() }
            } label: {
                Text(page < pages.count - 1 ? "التالي" : "ابدأ").font(.headline).frame(maxWidth: .infinity).padding()
                    .background(Color("Gold"), in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.black)
            }
            .padding(24)
        }
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [Color("LaunchBackground"), .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }
}
