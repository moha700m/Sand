import Foundation

public enum ModelBadge: String, Codable, CaseIterable, Sendable {
    case arabic, saudi, fast, tools, coder, thinking, multilingual, recommended

    public var title: String {
        switch self {
        case .arabic: return "عربي"
        case .saudi: return "سعودي"
        case .fast: return "سريع"
        case .tools: return "أدوات"
        case .coder: return "برمجة"
        case .thinking: return "تفكير"
        case .multilingual: return "متعدد اللغات"
        case .recommended: return "موصى به"
        }
    }

    public var icon: String {
        switch self {
        case .arabic: return "character.book.closed.ar"
        case .saudi: return "star.circle"
        case .fast: return "hare"
        case .tools: return "wrench.and.screwdriver"
        case .coder: return "chevron.left.forwardslash.chevron.right"
        case .thinking: return "brain"
        case .multilingual: return "globe"
        case .recommended: return "hand.thumbsup"
        }
    }
}

public struct ModelInfo: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var publisher: String
    public var summary: String
    public var repo: String
    public var file: String
    public var sizeBytes: Int64
    public var parameters: String
    public var contextLength: Int
    public var badges: [ModelBadge]
    public var license: String
    /// True for models the user imported from Files.
    public var isLocalImport: Bool = false

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)?download=true")!
    }

    public var fileName: String { file }

    /// Rough RAM needed: weights + KV cache + runtime overhead.
    public var estimatedMemoryBytes: Int64 { Int64(Double(sizeBytes) * 1.2) + 350_000_000 }

    public init(id: String, name: String, publisher: String, summary: String, repo: String, file: String,
                sizeBytes: Int64, parameters: String, contextLength: Int, badges: [ModelBadge], license: String,
                isLocalImport: Bool = false) {
        self.id = id; self.name = name; self.publisher = publisher; self.summary = summary; self.repo = repo
        self.file = file; self.sizeBytes = sizeBytes; self.parameters = parameters; self.contextLength = contextLength
        self.badges = badges; self.license = license; self.isLocalImport = isLocalImport
    }
}

public enum ModelCatalog {
    public static let models: [ModelInfo] = [
        ModelInfo(id: "qwen3-1.7b", name: "Qwen3 1.7B", publisher: "Alibaba Qwen",
                  summary: "أفضل توازن للسرعة والجودة على أغلب الأجهزة. يدعم العربية واستدعاء الأدوات ووضع التفكير.",
                  repo: "Qwen/Qwen3-1.7B-GGUF", file: "Qwen3-1.7B-Q8_0.gguf",
                  sizeBytes: 1_830_000_000, parameters: "1.7B", contextLength: 32768,
                  badges: [.recommended, .arabic, .tools, .thinking, .multilingual], license: "Apache-2.0"),
        ModelInfo(id: "qwen3-4b", name: "Qwen3 4B", publisher: "Alibaba Qwen",
                  summary: "أذكى للوكلاء والأدوات والمهام متعددة الخطوات. يحتاج 6GB رام أو أكثر.",
                  repo: "Qwen/Qwen3-4B-GGUF", file: "Qwen3-4B-Q4_K_M.gguf",
                  sizeBytes: 2_500_000_000, parameters: "4B", contextLength: 32768,
                  badges: [.arabic, .tools, .thinking, .coder, .multilingual], license: "Apache-2.0"),
        ModelInfo(id: "allam-7b", name: "ALLaM 7B", publisher: "سدايا (SDAIA)",
                  summary: "نموذج سعودي من الهيئة السعودية للبيانات والذكاء الاصطناعي، مدرّب بعمق على العربية والثقافة السعودية. للأجهزة ذات 8GB رام.",
                  repo: "bartowski/ALLaM-AI_ALLaM-7B-Instruct-preview-GGUF", file: "ALLaM-AI_ALLaM-7B-Instruct-preview-Q4_K_M.gguf",
                  sizeBytes: 4_220_000_000, parameters: "7B", contextLength: 4096,
                  badges: [.saudi, .arabic], license: "Apache-2.0"),
        ModelInfo(id: "gemma3-4b", name: "Gemma 3 4B", publisher: "Google",
                  summary: "عربي ممتاز وكتابة طبيعية، مناسب للتلخيص والترجمة.",
                  repo: "ggml-org/gemma-3-4b-it-GGUF", file: "gemma-3-4b-it-Q4_K_M.gguf",
                  sizeBytes: 2_490_000_000, parameters: "4B", contextLength: 8192,
                  badges: [.arabic, .multilingual], license: "Gemma"),
        ModelInfo(id: "gemma3-1b", name: "Gemma 3 1B", publisher: "Google",
                  summary: "خفيف وسريع جداً للأجهزة القديمة.",
                  repo: "ggml-org/gemma-3-1b-it-GGUF", file: "gemma-3-1b-it-Q4_K_M.gguf",
                  sizeBytes: 806_000_000, parameters: "1B", contextLength: 8192,
                  badges: [.fast, .multilingual], license: "Gemma"),
        ModelInfo(id: "llama3.2-3b", name: "Llama 3.2 3B", publisher: "Meta",
                  summary: "قوي في الإنجليزية والبرمجة واستدعاء الأدوات.",
                  repo: "bartowski/Llama-3.2-3B-Instruct-GGUF", file: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
                  sizeBytes: 2_020_000_000, parameters: "3B", contextLength: 8192,
                  badges: [.tools, .coder], license: "Llama 3.2"),
        ModelInfo(id: "llama3.2-1b", name: "Llama 3.2 1B", publisher: "Meta",
                  summary: "صغير وسريع للمهام البسيطة.",
                  repo: "bartowski/Llama-3.2-1B-Instruct-GGUF", file: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
                  sizeBytes: 808_000_000, parameters: "1B", contextLength: 8192,
                  badges: [.fast], license: "Llama 3.2"),
        ModelInfo(id: "qwen2.5-0.5b", name: "Qwen2.5 0.5B", publisher: "Alibaba Qwen",
                  summary: "الأصغر — للتجربة السريعة على أي آيفون.",
                  repo: "Qwen/Qwen2.5-0.5B-Instruct-GGUF", file: "qwen2.5-0.5b-instruct-q8_0.gguf",
                  sizeBytes: 676_000_000, parameters: "0.5B", contextLength: 32768,
                  badges: [.fast, .arabic], license: "Apache-2.0"),
    ]

    public static func model(id: String) -> ModelInfo? { models.first { $0.id == id } }

    /// Picks a sensible default for the device's RAM.
    public static func recommended(forMemory bytes: UInt64) -> ModelInfo {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 7.5 { return model(id: "qwen3-4b")! }
        if gb >= 5.5 { return model(id: "qwen3-1.7b")! }
        return model(id: "gemma3-1b")!
    }

    public static func fits(_ m: ModelInfo, memory bytes: UInt64) -> Bool {
        // iOS lets an app use roughly 55–65% of physical RAM (more with the increased-memory entitlement).
        Double(m.estimatedMemoryBytes) <= Double(bytes) * 0.65
    }
}
