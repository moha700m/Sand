import Foundation

public enum ArabicText {
    /// Normalises Arabic for search: strips tashkeel/tatweel, unifies alef/ya/ta-marbuta forms, lowercases Latin.
    public static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x064B...0x065F, 0x0670, 0x0640: continue // harakat, superscript alef, tatweel
            case 0x0622, 0x0623, 0x0625, 0x0671: out.append(UnicodeScalar(0x0627)!) // آ أ إ ٱ -> ا
            case 0x0649: out.append(UnicodeScalar(0x064A)!) // ى -> ي
            case 0x0629: out.append(UnicodeScalar(0x0647)!) // ة -> ه
            case 0x0624: out.append(UnicodeScalar(0x0648)!) // ؤ -> و
            case 0x0626: out.append(UnicodeScalar(0x064A)!) // ئ -> ي
            default: out.append(u)
            }
        }
        return String(out).applyingArabicDigits().lowercased()
    }

    static let stopwords: Set<String> = [
        "في", "من", "علي", "الي", "عن", "ان", "او", "ما", "لا", "هل", "هو", "هي", "مع", "هذا", "هذه",
        "ذلك", "التي", "الذي", "كان", "قد", "ثم", "كل", "و", "يا", "لم", "لن", "اي", "بين", "عند",
        "the", "a", "an", "of", "to", "in", "and", "or", "is", "are", "for", "on", "with", "what", "how",
    ]

    public static func tokens(_ s: String) -> [String] {
        normalize(s)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopwords.contains($0) }
            .map(stem)
    }

    /// Very light Arabic prefix stripping (ال، وال، بال، كال، فال، لل).
    static func stem(_ w: String) -> String {
        for p in ["وال", "بال", "كال", "فال", "لل", "ال"] where w.hasPrefix(p) && w.count - p.count >= 2 {
            return String(w.dropFirst(p.count))
        }
        return w
    }
}

/// Okapi BM25 index over text chunks.
public struct BM25Index: Sendable {
    public struct Hit: Equatable, Sendable { public var index: Int; public var score: Double }

    private var docs: [[String: Int]] = []
    private var lengths: [Int] = []
    private var df: [String: Int] = [:]
    private let k1 = 1.5, b = 0.75

    public init(documents: [String] = []) { documents.forEach { add($0) } }

    public var count: Int { docs.count }

    public mutating func add(_ text: String) {
        let toks = ArabicText.tokens(text)
        var tf: [String: Int] = [:]
        toks.forEach { tf[$0, default: 0] += 1 }
        tf.keys.forEach { df[$0, default: 0] += 1 }
        docs.append(tf)
        lengths.append(toks.count)
    }

    public func search(_ query: String, limit: Int = 5) -> [Hit] {
        guard !docs.isEmpty else { return [] }
        let q = Set(ArabicText.tokens(query))
        let n = Double(docs.count)
        let avg = Double(lengths.reduce(0, +)) / n
        var hits: [Hit] = []
        for (i, tf) in docs.enumerated() {
            var score = 0.0
            for t in q {
                guard let f = tf[t] else { continue }
                let d = Double(df[t] ?? 0)
                let idf = log(1 + (n - d + 0.5) / (d + 0.5))
                let freq = Double(f)
                score += idf * (freq * (k1 + 1)) / (freq + k1 * (1 - b + b * Double(lengths[i]) / max(avg, 1)))
            }
            if score > 0 { hits.append(Hit(index: i, score: score)) }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }
}

public enum TextChunker {
    /// Splits text into overlapping chunks of roughly `size` characters, preferring paragraph/sentence boundaries.
    public static func chunk(_ text: String, size: Int = 800, overlap: Int = 120) -> [String] {
        let clean = text.replacingOccurrences(of: "\r", with: "")
        let paragraphs = clean.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var chunks: [String] = []
        var current = ""
        for p in paragraphs {
            if current.count + p.count + 2 <= size {
                current += current.isEmpty ? p : "\n\n" + p
                continue
            }
            if !current.isEmpty { chunks.append(current) }
            if p.count <= size {
                current = String(current.suffix(overlap))
                current = current.isEmpty ? p : current + "\n\n" + p
                if current.count > size { current = p }
            } else {
                var start = p.startIndex
                while start < p.endIndex {
                    let end = p.index(start, offsetBy: size, limitedBy: p.endIndex) ?? p.endIndex
                    chunks.append(String(p[start..<end]))
                    if end == p.endIndex { break }
                    start = p.index(end, offsetBy: -overlap, limitedBy: p.startIndex) ?? end
                }
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
