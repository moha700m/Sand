import Foundation
#if canImport(os)
import os
#endif
#if canImport(Darwin)
import Darwin
#endif

/// How comfortably a model fits *this* device right now.
public enum FitVerdict: String, Sendable {
    case fits, tight, tooBig, unknown

    public var title: String {
        switch self {
        case .fits: return "يناسب جهازك"
        case .tight: return "يعمل لكن بضيق"
        case .tooBig: return "أكبر من ذاكرة جهازك"
        case .unknown: return "الحجم غير معروف"
        }
    }

    public var icon: String {
        switch self {
        case .fits: return "checkmark.seal.fill"
        case .tight: return "exclamationmark.triangle.fill"
        case .tooBig: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Memory guidance shared by the catalog, the Hugging Face browser and the loader.
///
/// Peak working set ≈ weights × 1.3 (KV cache + activations) + 300 MB of glue,
/// compared against the smaller of "what iOS says is available to this process"
/// and a conservative share of physical RAM. Inspired by the MemoryAdvisor
/// design in Mesutcydev/ios-local-llm (MIT); this is an independent, simplified
/// implementation.
public enum DeviceCapacity {
    public static var physical: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }

    /// Bytes iOS is still willing to give this process; 0 when unavailable (simulator).
    public static var available: Int64 {
        #if os(iOS) && !targetEnvironment(simulator)
        let value = Int64(os_proc_available_memory())
        return value > 0 ? value : 0
        #else
        return 0
        #endif
    }

    /// Conservative budget used for verdicts.
    public static var budget: Int64 {
        let byPhysical = Int64(Double(physical) * 0.6)
        guard available > 0 else { return byPhysical }
        return min(byPhysical, Int64(Double(available) * 0.9))
    }

    public static func peakBytes(forWeights weights: Int64) -> Int64 {
        guard weights > 0 else { return 0 }
        return Int64(Double(weights) * 1.3) + 300_000_000
    }

    public static func verdict(forWeights weights: Int64) -> FitVerdict {
        guard weights > 0 else { return .unknown }
        let peak = peakBytes(forWeights: weights)
        if peak <= Int64(Double(budget) * 0.75) { return .fits }
        if peak <= budget { return .tight }
        return .tooBig
    }

    public static func verdict(for model: ModelInfo) -> FitVerdict {
        verdict(forWeights: model.sizeBytes)
    }

    /// "6.0 GB · متاح الآن 2.4 GB"
    public static var summary: String {
        let b = ByteCountFormatter()
        b.countStyle = .memory
        var text = b.string(fromByteCount: physical)
        if available > 0 { text += " · متاح الآن " + b.string(fromByteCount: available) }
        return text
    }

    public static var budgetDescription: String {
        ByteCountFormatter.string(fromByteCount: budget, countStyle: .memory)
    }
}
