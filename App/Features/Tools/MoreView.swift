import SwiftUI
import UniformTypeIdentifiers

struct MoreView: View {
    @EnvironmentObject var state: AppState
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("البناء") {
                    NavigationLink(value: "tools") { row("الأدوات", "hammer.fill", .pink, "\(state.userTools.all.count) أداة منشأة") }
                    NavigationLink(value: "workspace") { row("مساحة العمل", "folder.fill", .orange, "\(state.packages.count) مساحة · \(state.workspace.totalBytes(state.workspaceContext.agentID).fileSize)") }
                    NavigationLink(value: "skills") { row("المهارات", "books.vertical.fill", .teal, "\(state.skills.all.count) مهارة · SKILL.md") }
                    NavigationLink(value: "importModel") { row("إضافة نموذج بالرابط", "arrow.down.circle", .indigo, "Hugging Face · GGUF") }
                    NavigationLink(value: "arena") { row("الساحة", "trophy", .yellow, "مقارنة أ/ب · وضع أعمى · تصنيف Elo") }
                    NavigationLink(value: "modelDetail") { row("قياس النموذج", "speedometer", .mint, "سرعة · تقييم جودة · إعدادات") }
                }
                Section {
                    NavigationLink(value: "lens") { row("العدسة", "camera.viewfinder", .cyan, "قراءة نص من صورة ثم شرح أو ترجمة") }
                    NavigationLink(value: "saudi") { row("أدوات سعودية", "star.circle.fill", .green, "هجري، صلاة، قبلة، زكاة، ضريبة، نهاية خدمة") }
                    NavigationLink(value: "knowledge") { row("قاعدة المعرفة", "books.vertical.fill", .orange, "\(state.knowledge.documents.count) مستند") }
                    NavigationLink(value: "notes") { row("الملاحظات", "note.text", .yellow, "\(state.notes.notes.count) ملاحظة") }
                }
                Section("القوة") {
                    NavigationLink(value: "providers") { row("مزودو السحابة", "cloud.bolt.fill", .indigo, "\(state.providers.count) مزود · GPT · Claude · Gemini") }
                    NavigationLink(value: "mcp") { row("خوادم MCP", "puzzlepiece.extension.fill", .purple, "\(state.mcp.servers.filter(\.enabled).count) مفعّل · \(state.mcp.totalTools) أداة") }
                    NavigationLink(value: "memory") { row("الذاكرة والتخصيص", "brain.head.profile", .pink, "\(state.memory.all.count) ذكرى") }
                }
                Section {
                    NavigationLink(value: "server") { row("خادم API المحلي", "server.rack", .blue, state.server.isRunning ? "يعمل" : "متوقف") }
                    NavigationLink(value: "settings") { row("الإعدادات", "gearshape.fill", .gray, "النموذج، المظهر، الخصوصية") }
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("سَنَد AI").font(.headline)
                        Text("ذكاء اصطناعي محلي وسحابي بهوية سعودية. النماذج المحلية تعمل بدون إنترنت، والسحابية والويب وMCP تستخدم الإنترنت لقوة أكبر. لا حساب ولا تحليلات.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("المزيد")
            .navigationDestination(for: String.self) { s in
                switch s {
                case "tools": ToolsView()
                case "workspace": WorkspaceView()
                case "skills": SkillsView()
                case "importModel": ModelImportView()
                case "arena": ArenaView()
                case "modelDetail": ModelDetailView(ref: "local", displayName: state.models.activeModel?.name ?? "نموذج محلي")
                case "lens": LensView()
                case "saudi": SaudiToolsView()
                case "knowledge": KnowledgeView()
                case "notes": NotesView()
                case "server": ServerView()
                case "providers": ProvidersView()
                case "mcp": MCPServersView(mcp: state.mcp)
                case "memory": MemoryView()
                default: SettingsView()
                }
            }
            .onAppear(perform: openDeepLink)
            .onChange(of: state.deepLinkScreen) { _, _ in openDeepLink() }
        }
    }

    func openDeepLink() {
        if let s = state.deepLinkScreen, ["saudi", "server", "knowledge", "settings", "providers", "mcp", "memory", "tools", "workspace", "skills", "lens", "importModel", "arena", "modelDetail"].contains(s) {
            state.deepLinkScreen = nil
            path.append(s)
        }
    }

    func row(_ t: String, _ icon: String, _ c: Color, _ sub: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.white).frame(width: 32, height: 32).background(c, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading) {
                Text(t)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Saudi tools

struct SaudiToolsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var date = Date()
    @State private var hijriInput = ""
    @State private var hijriOutput = ""
    @State private var vatAmount = ""
    @State private var vatExtract = false
    @State private var cash = ""
    @State private var gold = ""
    @State private var wage = ""
    @State private var years = ""
    @State private var resign = false
    @State private var calc = ""
    @State private var calcResult = ""

    var city: PrayerTimes.City { PrayerTimes.city(named: settings.defaultCity) ?? PrayerTimes.cities[0] }

    var body: some View {
        Form {
            Section("التاريخ") {
                Text(Hijri.describe(Date())).font(.headline)
                TextField("حوّل تاريخاً: 1447-09-01 أو 2026-03-11", text: $hijriInput)
                    .keyboardType(.numbersAndPunctuation)
                    .onSubmit(convertDate)
                if !hijriOutput.isEmpty { Text(hijriOutput).foregroundStyle(.secondary) }
            }
            Section("مواقيت الصلاة — أم القرى") {
                Picker("المدينة", selection: $settings.defaultCity) {
                    ForEach(PrayerTimes.cities) { Text($0.name).tag($0.name) }
                }
                let t = PrayerTimes.compute(date: Date(), latitude: city.latitude, longitude: city.longitude)
                ForEach(Array(t.ordered.enumerated()), id: \.offset) { _, p in
                    HStack {
                        Text(p.name)
                        Spacer()
                        Text(Self.riyadhTime(p.time)).monospacedDigit()
                            .foregroundStyle(t.next(after: Date())?.name == p.name ? Color.accentColor : .secondary)
                    }
                }
                HStack {
                    Label("القبلة", systemImage: "location.north.line.fill")
                    Spacer()
                    Text(String(format: "%.1f° · %.0f كم", Qibla.bearing(latitude: city.latitude, longitude: city.longitude),
                                Qibla.distanceKm(latitude: city.latitude, longitude: city.longitude)))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Section("ضريبة القيمة المضافة 15%") {
                TextField("المبلغ بالريال", text: $vatAmount).keyboardType(.decimalPad)
                Toggle("المبلغ شامل الضريبة", isOn: $vatExtract)
                if let a = Decimal(arabic: vatAmount) {
                    let b = vatExtract ? VAT.extract(from: a) : VAT.add(to: a)
                    LabeledContent("قبل الضريبة", value: b.net.sar)
                    LabeledContent("الضريبة", value: b.vat.sar)
                    LabeledContent("الإجمالي", value: b.gross.sar).bold()
                }
            }
            Section("الزكاة") {
                TextField("النقد والأرصدة (ريال)", text: $cash).keyboardType(.decimalPad)
                TextField("سعر جرام الذهب عيار 24 (ريال)", text: $settings.goldPrice).keyboardType(.decimalPad)
                TextField("ذهب للادخار (جرام)", text: $gold).keyboardType(.decimalPad)
                let r = zakat
                LabeledContent("الوعاء", value: r.totalWealth.sar)
                LabeledContent("النصاب", value: r.nisab > 0 ? r.nisab.sar : "أدخل سعر الذهب")
                LabeledContent("الزكاة", value: r.isDue ? r.zakat.sar : "لم يبلغ النصاب").bold()
            }
            Section("مكافأة نهاية الخدمة") {
                TextField("آخر راتب شامل (ريال)", text: $wage).keyboardType(.decimalPad)
                TextField("سنوات الخدمة", text: $years).keyboardType(.decimalPad)
                Toggle("استقالة", isOn: $resign)
                if let w = Decimal(arabic: wage), let y = Decimal(arabic: years) {
                    LabeledContent("المكافأة", value: EndOfService.compute(monthlyWage: w, years: y, reason: resign ? .resignation : .terminatedByEmployer).sar).bold()
                }
                Text("تقديري وفق المادتين 84 و85 من نظام العمل.").font(.caption).foregroundStyle(.secondary)
            }
            Section("الحاسبة الدقيقة") {
                TextField("مثال: (4599/1.15)*12", text: $calc)
                    .keyboardType(.numbersAndPunctuation)
                    .environment(\.layoutDirection, .leftToRight)
                    .onChange(of: calc) { _, v in
                        calcResult = (try? Calculator.evaluate(v)).map(Calculator.format) ?? ""
                    }
                if !calcResult.isEmpty { Text("= \(calcResult)").font(.title3.monospacedDigit()) }
            }
        }
        .navigationTitle("أدوات سعودية")
    }

    var zakat: Zakat.Result {
        var i = Zakat.Input()
        i.cash = Decimal(arabic: cash) ?? 0
        i.goldGrams24k = Decimal(arabic: gold) ?? 0
        i.goldPricePerGram = Decimal(arabic: settings.goldPrice) ?? 0
        return Zakat.compute(i)
    }

    /// Prayer times are calculated for Saudi Arabia, so always display them in Riyadh time.
    static func riyadhTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar_SA")
        f.timeZone = Hijri.riyadh
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    func convertDate() {
        guard let p = Hijri.parse(hijriInput) else { hijriOutput = "صيغة غير صحيحة"; return }
        let d = p.year < 1600 ? Hijri.date(hijri: p) : Hijri.date(gregorian: p)
        hijriOutput = d.map(Hijri.describe) ?? "تاريخ غير صالح"
    }
}

// MARK: - Knowledge

struct KnowledgeView: View {
    @EnvironmentObject var state: AppState
    @State private var importing = false
    @State private var docs: [KnowledgeDocument] = []
    @State private var query = ""
    @State private var error: String?
    @State private var pasteTitle = ""
    @State private var pasteText = ""
    @State private var showPaste = false

    var body: some View {
        List {
            Section {
                Text("أضف ملفات PDF أو نصوص، ثم اسأل «باحث المستندات» عنها. البحث والفهرسة على جهازك بالكامل.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !docs.isEmpty {
                Section("تجربة البحث") {
                    TextField("ابحث في مستنداتك", text: $query)
                    ForEach(Array(state.knowledge.search(query, limit: 3).enumerated()), id: \.offset) { _, h in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(h.documentTitle).font(.caption.bold())
                            Text(h.chunk).font(.caption).lineLimit(4).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("المستندات") {
                if docs.isEmpty { Text("لا توجد مستندات بعد").foregroundStyle(.secondary) }
                ForEach(docs) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.title).font(.headline)
                        Text("\(d.chunks.count) مقطع · \(d.characterCount) حرف").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in idx.forEach { state.knowledge.remove(id: docs[$0].id) }; reload() }
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .navigationTitle("قاعدة المعرفة")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { importing = true } label: { Label("استيراد ملف (PDF / TXT / MD)", systemImage: "doc.badge.plus") }
                    Button { showPaste = true } label: { Label("لصق نص", systemImage: "doc.on.clipboard") }
                } label: { Image(systemName: "plus") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .plainText, .text, UTType(filenameExtension: "md") ?? .text],
                      allowsMultipleSelection: true) { r in
            if case .success(let urls) = r {
                for u in urls {
                    do { state.knowledge.add(title: u.deletingPathExtension().lastPathComponent, text: try DocumentImporter.text(from: u)) }
                    catch { self.error = error.localizedDescription }
                }
                reload()
            }
        }
        .sheet(isPresented: $showPaste) {
            NavigationStack {
                Form {
                    TextField("العنوان", text: $pasteTitle)
                    TextEditor(text: $pasteText).frame(minHeight: 240)
                }
                .navigationTitle("لصق نص")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("حفظ") {
                            state.knowledge.add(title: pasteTitle.isEmpty ? "نص" : pasteTitle, text: pasteText)
                            pasteTitle = ""; pasteText = ""; showPaste = false; reload()
                        }.disabled(pasteText.isEmpty)
                    }
                    ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { showPaste = false } }
                }
            }
        }
        .onAppear(perform: reload)
    }

    func reload() { docs = state.knowledge.documents }
}

struct NotesView: View {
    @EnvironmentObject var state: AppState
    @State private var notes: [Note] = []

    var body: some View {
        List {
            if notes.isEmpty { Text("الوكلاء يحفظون الملاحظات والمقتطفات هنا.").foregroundStyle(.secondary) }
            ForEach(notes) { n in
                VStack(alignment: .leading, spacing: 4) {
                    Text(n.title).font(.headline)
                    Text(n.body).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(n.date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .onDelete { idx in idx.forEach { state.notes.remove(id: notes[$0].id) }; notes = state.notes.notes }
        }
        .navigationTitle("الملاحظات")
        .onAppear { notes = state.notes.notes }
    }
}
