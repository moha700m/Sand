import SwiftUI
import UniformTypeIdentifiers

/// Everything that does not need its own tab, in one short list.
/// Each entry is a real destination; nothing here is decorative.
enum MoreRoute: String, Hashable, CaseIterable {
    case agents, tools, skills, workspace, arena, lens
    case knowledge, notes, memory
    case providers, mcp, server
    case saudi, settings
}

struct MoreView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var runner: AgentRunner
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        NavigationLink(value: MoreRoute.tools) {
                            MoreTile(icon: "hammer.fill", color: .pink, title: "الأدوات",
                                     subtitle: "\(state.userTools.all.count) منشأة")
                        }
                        NavigationLink(value: MoreRoute.skills) {
                            MoreTile(icon: "books.vertical.fill", color: .teal, title: "المهارات",
                                     subtitle: "\(state.skills.all.count) مهارة")
                        }
                        NavigationLink(value: MoreRoute.workspace) {
                            MoreTile(icon: "folder.fill", color: .orange, title: "مساحة العمل",
                                     subtitle: state.workspace.totalBytes(state.workspaceContext.agentID).fileSize)
                        }
                        NavigationLink(value: MoreRoute.arena) {
                            MoreTile(icon: "trophy.fill", color: .yellow, title: "الساحة",
                                     subtitle: "مقارنة أ/ب")
                        }
                        NavigationLink(value: MoreRoute.lens) {
                            MoreTile(icon: "camera.viewfinder", color: .cyan, title: "العدسة",
                                     subtitle: "نص من صورة")
                        }
                        NavigationLink(value: MoreRoute.agents) {
                            MoreTile(icon: "wand.and.stars", color: .purple, title: "الوكلاء",
                                     subtitle: runner.activeJobs.isEmpty ? "مهام في الخلفية" : "\(runner.activeJobs.count) مهمة جارية")
                        }
                    }
                    .buttonStyle(.plain)

                    group("بياناتك", [
                        (.knowledge, "doc.text.magnifyingglass", .indigo, "قاعدة المعرفة", "\(state.knowledge.documents.count) مستند"),
                        (.notes, "note.text", .yellow, "الملاحظات", "\(state.notes.notes.count) ملاحظة"),
                        (.memory, "brain.head.profile", .pink, "الذاكرة والتخصيص", "\(state.memory.all.count) ذكرى"),
                    ])

                    group("التشغيل", [
                        (.providers, "cloud.bolt.fill", .indigo, "مزودو السحابة", state.providers.isEmpty ? "لم يُضف مزود" : "\(state.providers.count) مزود"),
                        (.mcp, "puzzlepiece.extension.fill", .purple, "خوادم MCP", "\(state.mcp.servers.filter(\.enabled).count) مفعّل"),
                        (.server, "server.rack", .blue, "خادم API المحلي", state.server.isRunning ? "يعمل" : "متوقف"),
                    ])

                    group("عام", [
                        (.saudi, "star.circle.fill", .green, "أدوات سعودية", "هجري · صلاة · زكاة · نهاية خدمة"),
                        (.settings, "gearshape.fill", .gray, "الإعدادات", "النموذج، المظهر، الخصوصية"),
                    ])

                    VStack(spacing: 4) {
                        Text("سَنَد AI").font(.footnote.weight(.semibold))
                        Text("ذكاء اصطناعي محلي وسحابي بهوية سعودية. لا حساب ولا تحليلات.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)
                }
                .padding()
                .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("المزيد")
            .navigationDestination(for: MoreRoute.self) { destination($0) }
            .onAppear(perform: openDeepLink)
            .onChange(of: state.deepLinkScreen) { _, _ in openDeepLink() }
        }
    }

    var statusCard: some View {
        Button { state.tab = .models } label: {
            HStack(spacing: 12) {
                Image(systemName: state.engineReady ? "cpu.fill" : "cpu")
                    .font(.title2)
                    .foregroundStyle(state.engineReady ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.engineReady ? (models.activeModel?.name ?? "نموذج محلي") : "لا يوجد نموذج محمّل")
                        .font(.headline).foregroundStyle(.primary)
                    Text(state.engineReady ? "يعمل على الجهاز" : "اختر نموذجاً للبدء")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(runner.activeJobs.count) مهمة جارية")
                        .font(.caption2).foregroundStyle(runner.activeJobs.isEmpty ? Color.secondary : Color.accentColor)
                    Text("\(models.installed.count) نموذج مثبّت")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    func group(_ title: String, _ rows: [(MoreRoute, String, Color, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    NavigationLink(value: row.0) {
                        HStack(spacing: 12) {
                            Image(systemName: row.1)
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(row.2, in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.3).foregroundStyle(.primary)
                                Text(row.4).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.left")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder func destination(_ route: MoreRoute) -> some View {
        switch route {
        case .agents: AgentBuilderView()
        case .tools: ToolsView()
        case .skills: SkillsView()
        case .workspace: WorkspaceView()
        case .arena: ArenaView()
        case .lens: LensView()
        case .knowledge: KnowledgeView()
        case .notes: NotesView()
        case .memory: MemoryView()
        case .providers: ProvidersView()
        case .mcp: MCPServersView(mcp: state.mcp)
        case .server: ServerView()
        case .saudi: SaudiToolsView()
        case .settings: SettingsView()
        }
    }

    func openDeepLink() {
        guard let raw = state.deepLinkScreen, let route = MoreRoute(rawValue: raw) else { return }
        state.deepLinkScreen = nil
        path = NavigationPath()
        path.append(route)
    }
}

struct MoreTile: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
