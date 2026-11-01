import SwiftUI

/// A/B arena with blind judging and a local Elo leaderboard.
struct ArenaView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    @State private var prompt = ""
    @State private var refA = "local"
    @State private var refB = ""
    @State private var blind = true
    @State private var running = false
    @State private var match: ArenaMatch?
    @State private var revealed = false
    @State private var error: String?
    @State private var boardVersion = 0

    struct Option: Identifiable, Hashable {
        let ref: String
        let name: String
        var id: String { ref }
    }

    var options: [Option] {
        var list: [Option] = []
        if let active = models.activeModel, state.engineReady {
            list.append(Option(ref: "local", name: active.name))
        } else {
            list.append(Option(ref: "local", name: "نموذج محلي"))
        }
        for p in state.providers { list.append(Option(ref: p.id, name: p.displayName)) }
        return list
    }

    var body: some View {
        List {
            Section {
                TextField("اكتب سؤالاً واحداً يقارن بين نموذجين…", text: $prompt, axis: .vertical)
                    .lineLimit(2...6)
            }

            Section("النموذجان") {
                Picker("أ", selection: $refA) {
                    ForEach(options) { o in Text(o.name).tag(o.ref) }
                }
                Picker("ب", selection: $refB) {
                    ForEach(options) { o in Text(o.name).tag(o.ref) }
                }
                Toggle("وضع أعمى (إخفاء الأسماء حتى التصويت)", isOn: $blind)
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        if running { ProgressView().controlSize(.small) }
                        Text(running ? "جاري التوليد…" : "ابدأ المقارنة")
                    }
                }
                .disabled(running || prompt.trimmingCharacters(in: .whitespaces).isEmpty || refA == refB)
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }

            if let m = match {
                Section("الإجابة أ") {
                    Text(m.answerA.isEmpty ? "—" : m.answerA).font(.callout).textSelection(.enabled)
                    HStack {
                        Text(String(format: "%.2f ث", m.secondsA)).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if revealed { Text(m.nameA).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section("الإجابة ب") {
                    Text(m.answerB.isEmpty ? "—" : m.answerB).font(.callout).textSelection(.enabled)
                    HStack {
                        Text(String(format: "%.2f ث", m.secondsB)).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if revealed { Text(m.nameB).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if m.winner == nil {
                    Section("صوّت") {
                        Button("أ أفضل") { vote(.a) }
                        Button("ب أفضل") { vote(.b) }
                        Button("تعادل") { vote(.tie) }
                    }
                } else {
                    Section {
                        Text("تم تسجيل التصويت — تحدّث تصنيفات Elo.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            leaderboardSection
        }
        .navigationTitle("الساحة")
        .onAppear {
            if refB.isEmpty { refB = options.first(where: { $0.ref != refA })?.ref ?? "local" }
        }
    }

    struct BoardRow: Identifiable {
        let id: String
        let rank: Int
        let name: String
        let rating: EloRating
    }

    var boardRows: [BoardRow] {
        _ = boardVersion
        return ArenaStore.shared.leaderboard.enumerated().map { index, row in
            BoardRow(id: row.name, rank: index + 1, name: row.name, rating: row.rating)
        }
    }

    var leaderboardSection: some View {
        let rows = boardRows
        return Section("التصنيف المحلي") {
            if rows.isEmpty {
                Text("لا تصويتات بعد. كل تصويت يبني تصنيفاً خاصاً بجهازك.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack {
                        Text("\(row.rank)").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.footnote.weight(.semibold))
                            Text("\(row.rating.wins) فوز · \(row.rating.losses) خسارة · \(row.rating.ties) تعادل")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.0f", row.rating.rating)).font(.callout.monospaced())
                    }
                }
                Button(role: .destructive) {
                    ArenaStore.shared.reset()
                    boardVersion += 1
                } label: { Label("تصفير التصنيف", systemImage: "trash") }
            }
        }
    }

    func run() async {
        error = nil
        match = nil
        revealed = false
        running = true
        defer { running = false }

        guard let a = options.first(where: { $0.ref == refA }),
              let b = options.first(where: { $0.ref == refB }) else { return }
        do {
            let result = try await ArenaRunner.run(
                prompt: prompt,
                a: ArenaRunner.Side(ref: a.ref, name: a.name),
                b: ArenaRunner.Side(ref: b.ref, name: b.name),
                backendA: state.backend(for: a.ref),
                backendB: state.backend(for: b.ref),
                settings: state.settings.generation,
                blind: blind)
            match = result
            if !blind { revealed = true }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func vote(_ w: ArenaMatch.Winner) {
        guard let m = match else { return }
        match = ArenaStore.shared.record(m, winner: w)
        revealed = true
        boardVersion += 1
    }
}
