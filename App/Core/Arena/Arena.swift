import Foundation

/// One A/B comparison between two models on the same prompt.
public struct ArenaMatch: Codable, Identifiable, Sendable {
    public enum Winner: String, Codable, Sendable { case a, b, tie }

    public var id: UUID
    public var prompt: String
    public var refA: String
    public var refB: String
    public var nameA: String
    public var nameB: String
    public var answerA: String
    public var answerB: String
    public var secondsA: Double
    public var secondsB: Double
    public var blind: Bool
    public var winner: Winner?
    public var date: Date

    public init(prompt: String, refA: String, refB: String, nameA: String, nameB: String,
                answerA: String, answerB: String, secondsA: Double, secondsB: Double,
                blind: Bool, winner: Winner? = nil, date: Date = Date()) {
        self.id = UUID(); self.prompt = prompt; self.refA = refA; self.refB = refB
        self.nameA = nameA; self.nameB = nameB; self.answerA = answerA; self.answerB = answerB
        self.secondsA = secondsA; self.secondsB = secondsB
        self.blind = blind; self.winner = winner; self.date = date
    }
}

public struct EloRating: Codable, Equatable, Sendable {
    public var rating: Double = 1200
    public var wins: Int = 0
    public var losses: Int = 0
    public var ties: Int = 0
    public var matches: Int { wins + losses + ties }
    public var winRate: Double { matches == 0 ? 0 : Double(wins) / Double(matches) }
    public init() {}
}

public enum Elo {
    /// Probability that A beats B.
    public static func expected(_ a: Double, _ b: Double) -> Double {
        1.0 / (1.0 + pow(10.0, (b - a) / 400.0))
    }

    /// Score: 1 = A wins, 0.5 = tie, 0 = B wins.
    public static func update(a: Double, b: Double, scoreA: Double, k: Double = 24) -> (Double, Double) {
        let ea = expected(a, b)
        let eb = 1 - ea
        return (a + k * (scoreA - ea), b + k * ((1 - scoreA) - eb))
    }
}

/// Persistent local leaderboard: every vote feeds an Elo rating for this device only.
public final class ArenaStore {
    public static let shared = ArenaStore(fileName: "arena.json")

    private let fileName: String?
    private let lock = NSLock()
    private var matches: [ArenaMatch] = []
    private var ratings: [String: EloRating] = [:]
    private var refs: [String: String] = [:]

    struct State: Codable {
        var matches: [ArenaMatch]
        var ratings: [String: EloRating]
        var refs: [String: String]
    }

    public init(fileName: String?) {
        self.fileName = fileName
        if let saved = fileName.flatMap({ Storage.load(State.self, from: $0) }) {
            matches = saved.matches
            ratings = saved.ratings
            refs = saved.refs
        }
    }

    public var allMatches: [ArenaMatch] { lock.lock(); defer { lock.unlock() }; return matches }

    @discardableResult
    public func record(_ match: ArenaMatch, winner: ArenaMatch.Winner) -> ArenaMatch {
        var m = match
        m.winner = winner
        lock.lock()
        matches.append(m)
        if ratings[m.nameA] == nil { ratings[m.nameA] = EloRating() }
        if ratings[m.nameB] == nil { ratings[m.nameB] = EloRating() }
        refs[m.nameA] = m.refA
        refs[m.nameB] = m.refB
        let ra = ratings[m.nameA]!.rating
        let rb = ratings[m.nameB]!.rating
        let scoreA: Double = winner == .a ? 1 : winner == .b ? 0 : 0.5
        let (na, nb) = Elo.update(a: ra, b: rb, scoreA: scoreA)
        ratings[m.nameA]!.rating = na
        ratings[m.nameB]!.rating = nb
        switch winner {
        case .a: ratings[m.nameA]!.wins += 1; ratings[m.nameB]!.losses += 1
        case .b: ratings[m.nameB]!.wins += 1; ratings[m.nameA]!.losses += 1
        case .tie: ratings[m.nameA]!.ties += 1; ratings[m.nameB]!.ties += 1
        }
        lock.unlock()
        persist()
        return m
    }

    public var leaderboard: [(name: String, ref: String, rating: EloRating)] {
        lock.lock(); defer { lock.unlock() }
        return ratings.map { (name: $0.key, ref: refs[$0.key] ?? "local", rating: $0.value) }
            .sorted { $0.rating.rating > $1.rating.rating }
    }

    public func reset() {
        lock.lock(); matches = []; ratings = [:]; refs = [:]; lock.unlock()
        persist()
    }

    private func persist() {
        guard let f = fileName else { return }
        lock.lock()
        let state = State(matches: matches, ratings: ratings, refs: refs)
        lock.unlock()
        Storage.save(state, to: f)
    }
}

/// Runs both sides sequentially: two local models must never be resident at once on iPhone.
public enum ArenaRunner {
    public struct Side: Sendable {
        public var ref: String
        public var name: String
        public init(ref: String, name: String) { self.ref = ref; self.name = name }
    }

    public static func run(prompt: String, a: Side, b: Side,
                           backendA: LLMBackend, backendB: LLMBackend,
                           settings: GenerationSettings, blind: Bool) async throws -> ArenaMatch {
        let startedA = Date()
        let resultA = try await backendA.generate(messages: [ChatMessage(role: .user, content: prompt)],
                                                  settings: settings, stop: []) { _ in true }
        let secondsA = Date().timeIntervalSince(startedA)

        let startedB = Date()
        let resultB = try await backendB.generate(messages: [ChatMessage(role: .user, content: prompt)],
                                                  settings: settings, stop: []) { _ in true }
        let secondsB = Date().timeIntervalSince(startedB)
        let answerA = resultA.text
        let answerB = resultB.text

        return ArenaMatch(prompt: prompt, refA: a.ref, refB: b.ref, nameA: a.name, nameB: b.name,
                          answerA: answerA, answerB: answerB, secondsA: secondsA, secondsB: secondsB,
                          blind: blind)
    }
}
