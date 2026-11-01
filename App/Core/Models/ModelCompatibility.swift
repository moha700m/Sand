import Foundation

public enum ModelFormat: String, Codable, CaseIterable, Sendable {
    case gguf, mlx, safetensors, unknown

    public var title: String {
        switch self {
        case .gguf: return "GGUF"
        case .mlx: return "MLX"
        case .safetensors: return "Safetensors"
        case .unknown: return "غير معروف"
        }
    }

    public static func detect(fileName: String) -> ModelFormat {
        let f = fileName.lowercased()
        if f.hasSuffix(".gguf") { return .gguf }
        if f.hasSuffix(".safetensors") { return .safetensors }
        if f.contains("mlx") || f.hasSuffix(".npz") { return .mlx }
        return .unknown
    }
}

public enum RuntimeAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    public var isAvailable: Bool { self == .available }
    public var reason: String? { if case .unavailable(let r) = self { return r }; return nil }
}

/// Tells the user the truth about what this build can actually run.
public enum RuntimeRegistry {
    public static func runtime(for format: ModelFormat) -> String {
        switch format {
        case .gguf: return "llama.cpp"
        case .mlx: return "MLX"
        case .safetensors: return "—"
        case .unknown: return "—"
        }
    }

    public static func availability(for format: ModelFormat) -> RuntimeAvailability {
        switch format {
        case .gguf:
            return .available
        case .mlx:
            #if canImport(MLXLLM)
            return .available
            #else
            return .unavailable("هذه النسخة لا تتضمن MLX. مدعوم حالياً: GGUF عبر llama.cpp.")
            #endif
        case .safetensors:
            return .unavailable("صيغة أوزان خام غير قابلة للتشغيل مباشرة. استخدم GGUF أو حزمة MLX.")
        case .unknown:
            return .unavailable("صيغة غير معروفة.")
        }
    }

    public static var summary: String {
        "المحرك المتاح: llama.cpp (GGUF). MLX غير مضمّن في هذه النسخة."
    }
}

public struct ModelCompatibility: Equatable, Sendable {
    public var format: ModelFormat
    public var runtime: String
    public var availability: RuntimeAvailability
    public var estimatedBytes: Int64
    public var fitsInMemory: Bool

    public var isRunnable: Bool { format == .gguf && availability.isAvailable && fitsInMemory }

    public var explanation: String {
        if let reason = availability.reason { return reason }
        if !fitsInMemory { return "الحجم المتوقع أكبر من الذاكرة المتاحة — قد يفشل التحميل." }
        return "متوافق مع \(runtime)."
    }

    public static func evaluate(fileName: String, sizeBytes: Int64, physicalMemory: UInt64) -> ModelCompatibility {
        let format = ModelFormat.detect(fileName: fileName)
        let estimated = Int64(Double(sizeBytes) * 1.2) + 350_000_000
        let fits = Double(estimated) <= Double(physicalMemory) * 0.65
        return ModelCompatibility(format: format, runtime: RuntimeRegistry.runtime(for: format),
                                  availability: RuntimeRegistry.availability(for: format),
                                  estimatedBytes: estimated, fitsInMemory: fits)
    }
}

/// Parses the shapes of Hugging Face URLs users actually paste.
public enum HuggingFaceURL {
    public struct Parsed: Equatable, Sendable {
        public var repo: String
        public var file: String
        public var directURL: URL?
    }

    public static func parse(_ raw: String) -> Parsed? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if let url = URL(string: s), let host = url.host, host.contains("huggingface.co") {
            let parts = url.path.split(separator: "/").map(String.init)
            // /<owner>/<repo>/resolve/<rev>/<path...>
            if let resolveIdx = parts.firstIndex(of: "resolve"), resolveIdx >= 2, parts.count > resolveIdx + 2 {
                let repo = parts[0] + "/" + parts[1]
                let file = parts[(resolveIdx + 2)...].joined(separator: "/")
                return Parsed(repo: repo, file: file, directURL: url)
            }
            // /<owner>/<repo>
            if parts.count >= 2, !parts.contains("blob") {
                return Parsed(repo: parts[0] + "/" + parts[1], file: "", directURL: url)
            }
            return nil
        }
        // owner/repo/file.gguf
        let parts = s.split(separator: "/").map(String.init)
        if parts.count >= 3 {
            let file = parts.dropFirst(2).joined(separator: "/")
            guard file.lowercased().hasSuffix(".gguf") else { return nil }
            return Parsed(repo: parts[0] + "/" + parts[1], file: file, directURL: nil)
        }
        return nil
    }

    public static func downloadURL(repo: String, file: String) -> URL? {
        guard !repo.isEmpty, !file.isEmpty else { return nil }
        return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)?download=true")
    }
}
