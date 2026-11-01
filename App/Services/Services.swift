import AVFoundation
import Foundation
import PDFKit
import Security
import Speech
import UIKit
import Vision

// MARK: - Keychain

enum Keychain {
    static func set(_ value: String, for key: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecAttrService as String: "sanad", kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecAttrService as String: "sanad", kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecAttrService as String: "sanad"]
        SecItemDelete(q as CFDictionary)
    }

    static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "sk-sanad-" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - OCR

enum OCRService {
    /// Recognises Arabic and English text on-device.
    static func recognize(_ image: UIImage) async throws -> String {
        guard let cg = image.cgImage else { return "" }
        return try await withCheckedThrowingContinuation { cont in
            let req = VNRecognizeTextRequest { req, err in
                if let err { cont.resume(throwing: err); return }
                let lines = (req.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.recognitionLanguages = ["ar-SA", "en-US"]
            req.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: cg, orientation: image.cgOrientation)
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([req]) } catch { cont.resume(throwing: error) }
            }
        }
    }
}

extension UIImage {
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

// MARK: - Documents

enum DocumentImporter {
    static func text(from url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw ToolError("تعذّر فتح ملف PDF") }
            var out = ""
            for i in 0..<doc.pageCount {
                if let p = doc.page(at: i)?.string { out += p + "\n\n" }
            }
            if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ToolError("ملف PDF لا يحتوي نصاً قابلاً للنسخ (قد يكون صوراً). استخدم العدسة لقراءته.")
            }
            return out
        }
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1256) { return s }
        throw ToolError("ترميز الملف غير مدعوم")
    }
}

extension String.Encoding {
    static let windowsCP1256 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue)))
}

// MARK: - Speech

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechService()

    @Published var transcript = ""
    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var error: String?

    private let synth = AVSpeechSynthesizer()
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ar-SA"))
    var onFinal: ((String) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func setLanguage(arabic: Bool) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: arabic ? "ar-SA" : "en-US"))
    }

    func toggleListening() {
        isListening ? stopListening() : startListening()
    }

    func startListening() {
        error = nil
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { self.error = "اسمح بالتعرّف على الكلام من الإعدادات."; return }
                AVAudioApplication.requestRecordPermission { ok in
                    Task { @MainActor in
                        guard ok else { self.error = "اسمح باستخدام المايكروفون من الإعدادات."; return }
                        self.beginSession()
                    }
                }
            }
        }
    }

    private func beginSession() {
        stopSpeaking()
        guard let recognizer, recognizer.isAvailable else { error = "التعرّف على الكلام غير متاح حالياً."; return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try s.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req
            transcript = ""
            let input = audio.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
            audio.prepare()
            try audio.start()
            isListening = true
            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if err != nil || (result?.isFinal ?? false) {
                        let final = self.transcript
                        self.stopListening()
                        if !final.isEmpty { self.onFinal?(final) }
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
            stopListening()
        }
    }

    func stopListening() {
        if audio.isRunning { audio.stop(); audio.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        isListening = false
    }

    func speak(_ text: String) {
        stopSpeaking()
        let clean = ThinkingFilter.strip(text).replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
        let u = AVSpeechUtterance(string: clean)
        let arabic = clean.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
        u.voice = AVSpeechSynthesisVoice(language: arabic ? "ar-SA" : "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        synth.speak(u)
        isSpeaking = true
    }

    func stopSpeaking() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
