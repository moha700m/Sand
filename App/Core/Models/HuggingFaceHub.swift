import Foundation

public struct HFRepo: Identifiable, Hashable, Sendable {
    public var id: String
    public var downloads: Int
    public var likes: Int
    public var tags: [String]
    public var updated: String?
}

public struct HFFile: Identifiable, Hashable, Sendable {
    public var path: String
    public var size: Int64
    public var id: String { path }
    public var fileName: String { (path as NSString).lastPathComponent }
    public var isSplit: Bool { path.contains("-0000") && path.contains("-of-") }
    public var isProjector: Bool { fileName.lowercased().contains("mmproj") }
}

public enum HFError: LocalizedError {
    case badURL
    case http(Int)
    case decoding
    case empty

    public var errorDescription: String? {
        switch self {
        case .badURL: return "رابط البحث غير صالح."
        case .http(let c): return "Hugging Face أرجع خطأ \(c). جرّب لاحقاً أو قلّل النتائج."
        case .decoding: return "تعذّر قراءة استجابة Hugging Face."
        case .empty: return "لا نتائج."
        }
    }
}

/// Thin client for the public Hugging Face API. Read-only: search repos, list files.
public enum HuggingFaceHub {
    static let base = "https://huggingface.co/api"

    public static func search(_ query: String, limit: Int = 25) async throws -> [HFRepo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var comps = URLComponents(string: base + "/models")!
        var items = [URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "sort", value: "downloads"),
                     URLQueryItem(name: "direction", value: "-1"),
                     URLQueryItem(name: "filter", value: "gguf")]
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "search", value: trimmed)) }
        comps.queryItems = items
        guard let url = comps.url else { throw HFError.badURL }

        var repos = try await request(url)
        if repos.isEmpty, !trimmed.isEmpty {
            // Some GGUF repos are not tagged; retry without the filter.
            var retry = URLComponents(string: base + "/models")!
            retry.queryItems = [URLQueryItem(name: "limit", value: String(limit)),
                                URLQueryItem(name: "sort", value: "downloads"),
                                URLQueryItem(name: "direction", value: "-1"),
                                URLQueryItem(name: "search", value: trimmed + " gguf")]
            if let u = retry.url { repos = (try? await request(u)) ?? [] }
        }
        return repos
    }

    static func request(_ url: URL) async throws -> [HFRepo] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("SanadAI/3.0 (iOS; local model browser)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HFError.http(status) }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw HFError.decoding }
        return arr.compactMap { obj in
            guard let id = obj["id"] as? String else { return nil }
            return HFRepo(id: id,
                          downloads: (obj["downloads"] as? NSNumber)?.intValue ?? 0,
                          likes: (obj["likes"] as? NSNumber)?.intValue ?? 0,
                          tags: (obj["tags"] as? [String]) ?? [],
                          updated: obj["lastModified"] as? String)
        }
    }

    public static func files(repo: String) async throws -> [HFFile] {
        guard var comps = URLComponents(string: base + "/models/" + repo + "/tree/main") else { throw HFError.badURL }
        comps.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        guard let url = comps.url else { throw HFError.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HFError.http(status) }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw HFError.decoding }

        return arr.compactMap { obj in
            guard (obj["type"] as? String) == "file", let path = obj["path"] as? String else { return nil }
            guard path.lowercased().hasSuffix(".gguf") else { return nil }
            let size = (obj["size"] as? NSNumber)?.int64Value ?? ((obj["lfs"] as? [String: Any])?["size"] as? NSNumber)?.int64Value ?? 0
            return HFFile(path: path, size: size)
        }
        .sorted { $0.size < $1.size }
    }

    public static func downloadURL(repo: String, file: String) -> URL? {
        guard !repo.isEmpty, !file.isEmpty, !file.contains("..") else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "\\")
        guard let encodedFile = file.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encodedFile)?download=true")
    }

    /// Human label for a quantization embedded in the filename.
    public static func quantization(of file: String) -> String {
        let name = file.uppercased()
        for q in ["Q8_0", "Q6_K", "Q5_K_M", "Q5_0", "Q4_K_M", "Q4_0", "Q3_K_M", "Q2_K", "F16", "FP16", "BF16"] {
            if name.contains(q) { return q }
        }
        return "—"
    }
}
