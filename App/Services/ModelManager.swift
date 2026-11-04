import Foundation
import SwiftUI
import UIKit

/// Downloads, imports, stores and loads GGUF models.
///
/// The downloader is deliberately a **foreground** `URLSession`. Background
/// sessions never deliver their delegate callbacks on sideloaded builds
/// (no `NSURLSession` relaunch), which is why this app never used one — but a
/// foreground session alone is not enough for multi-gigabyte files: a single
/// dropped packet, a 429 from the Hub, or the app going to the background used
/// to end the download for good. Everything below exists to make one download
/// survive all of that.
@MainActor
final class ModelManager: NSObject, ObservableObject {
    struct DownloadState: Equatable {
        var received: Int64 = 0
        var total: Int64 = 0
        var bytesPerSecond: Double = 0
        /// Terminal failure — the downloader stopped trying.
        var failed: String?
        /// Transient notice shown while an automatic retry is pending.
        var retrying: String?
        /// Progress kept, transfer stopped (user pause or app backgrounded).
        var paused: Bool = false
        var attempt: Int = 0
        var maxAttempts: Int = 0
        var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    }

    @Published private(set) var installed: [ModelInfo] = []
    @Published private(set) var downloads: [String: DownloadState] = [:]
    @Published private(set) var activeModelID: String?
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    let engine: LlamaEngine
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    private var lastProgressAt: [String: (Date, Int64)] = [:]
    /// Ad-hoc models added from a URL, keyed by id, so the download delegate can resolve them.
    private var registered: [String: ModelInfo] = [:]
    /// Automatic attempts already spent per model.
    private var attempts: [String: Int] = [:]
    /// Models paused automatically because the app left the foreground.
    private var autoPaused: Set<String> = []
    /// Models whose current task resumed from saved data.
    private var resumed: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    /// 1 initial try + 3 automatic retries. A 4th failure is shown to the user.
    private static let maxAttempts = 4
    /// Resume data older than this is thrown away: the Hub's signed CDN links expire.
    private static let resumeMaxAge: TimeInterval = 12 * 60 * 60

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // 90s matches the stall watchdog used by ios-local-llm: long enough for
        // the Hub's CDN to start streaming a multi-GB blob, short enough that a
        // dead socket is retried instead of hanging forever.
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }()

    static var modelsDirectory: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = d
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? v.setResourceValues(rv)
        return d
    }()

    /// Where in-flight resume data lives so an app kill does not restart a 2 GB file.
    static var resumeDirectory: URL = {
        let d = modelsDirectory.appendingPathComponent(".partial", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static let physicalMemory = ProcessInfo.processInfo.physicalMemory

    /// Free space that iOS is willing to give the app right now.
    static func freeSpace() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    init(engine: LlamaEngine) {
        self.engine = engine
        super.init()
        refreshInstalled()
        activeModelID = UserDefaults.standard.string(forKey: "activeModelID")
        observeLifecycle()
    }

    var activeModel: ModelInfo? { installed.first { $0.id == activeModelID } }

    func fileURL(for m: ModelInfo) -> URL { Self.modelsDirectory.appendingPathComponent(m.fileName) }

    func refreshInstalled() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.modelsDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var list: [ModelInfo] = []
        for f in files where f.pathExtension.lowercased() == "gguf" {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0 ?? 0) } ?? 0
            if var known = ModelCatalog.models.first(where: { $0.fileName == f.lastPathComponent }) {
                known.sizeBytes = size
                list.append(known)
            } else {
                let name = f.deletingPathExtension().lastPathComponent
                list.append(ModelInfo(id: "local-" + name, name: name, publisher: "مستورد", summary: "نموذج مستورد من الملفات",
                                      repo: "", file: f.lastPathComponent, sizeBytes: size, parameters: "—",
                                      contextLength: 4096, badges: [], license: "—", isLocalImport: true))
            }
        }
        installed = list.sorted { $0.name < $1.name }
    }

    func isInstalled(_ m: ModelInfo) -> Bool { installed.contains { $0.fileName == m.fileName } }

    /// Any model we know about: ad-hoc downloads, catalog entries, or installed files.
    func knownModel(_ id: String) -> ModelInfo? {
        registered[id] ?? ModelCatalog.model(id: id) ?? installed.first { $0.id == id }
    }

    struct InFlight: Identifiable {
        var model: ModelInfo
        var state: DownloadState
        var id: String { model.id }
    }

    /// Every download in progress or failed — including models added from a URL
    /// that exist nowhere in the catalog.
    var inFlight: [InFlight] {
        downloads.compactMap { id, st in
            guard let m = knownModel(id) else { return nil }
            return InFlight(model: m, state: st)
        }
        .sorted { $0.model.name < $1.model.name }
    }

    // MARK: Download

    func register(_ m: ModelInfo) { registered[m.id] = m }

    func download(_ m: ModelInfo) {
        registered[m.id] = m
        guard tasks[m.id] == nil else { return }
        lastError = nil
        autoPaused.remove(m.id)

        if let problem = spaceProblem(for: m) {
            var st = downloads[m.id] ?? DownloadState(total: m.sizeBytes)
            st.failed = problem
            st.retrying = nil
            st.paused = false
            downloads[m.id] = st
            return
        }

        if downloads[m.id] == nil || downloads[m.id]?.failed != nil || downloads[m.id]?.paused == true {
            attempts[m.id] = 0
        }
        var st = downloads[m.id] ?? DownloadState(total: m.sizeBytes)
        st.failed = nil
        st.retrying = nil
        st.paused = false
        st.attempt = attempts[m.id] ?? 0
        st.maxAttempts = Self.maxAttempts
        downloads[m.id] = st
        startTask(m)
    }

    /// Starts (or restarts) a URLSession task for a model, resuming when possible.
    private func startTask(_ m: ModelInfo) {
        guard tasks[m.id] == nil else { return }
        let task: URLSessionDownloadTask
        if let data = loadResumeData(m.id) {
            resumed.insert(m.id)
            task = session.downloadTask(withResumeData: data)
        } else {
            resumed.remove(m.id)
            var req = URLRequest(url: m.downloadURL)
            req.timeoutInterval = 90
            req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            req.setValue("SanadAI/3.3 (iOS; GGUF model download)", forHTTPHeaderField: "User-Agent")
            HuggingFaceHub.authorize(&req)
            task = session.downloadTask(with: req)
        }
        task.taskDescription = m.id
        tasks[m.id] = task
        var st = downloads[m.id] ?? DownloadState(total: m.sizeBytes)
        st.attempt = attempts[m.id] ?? 0
        st.maxAttempts = Self.maxAttempts
        st.retrying = nil
        st.paused = false
        downloads[m.id] = st
        task.resume()
    }

    func pause(_ m: ModelInfo) {
        guard let task = tasks[m.id] else {
            var st = downloads[m.id] ?? DownloadState(total: m.sizeBytes)
            guard st.failed == nil, !st.paused else { return }
            st.paused = true
            downloads[m.id] = st
            return
        }
        attempts[m.id] = 0
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                self.tasks[m.id] = nil
                if let data { self.persistResumeData(data, for: m.id) }
                var st = self.downloads[m.id] ?? DownloadState(total: m.sizeBytes)
                st.paused = true
                st.retrying = nil
                st.failed = nil
                self.downloads[m.id] = st
            }
        })
    }

    func cancel(_ m: ModelInfo) {
        tasks[m.id]?.cancel()
        tasks[m.id] = nil
        resumeData[m.id] = nil
        attempts[m.id] = nil
        autoPaused.remove(m.id)
        resumed.remove(m.id)
        clearResumeData(m.id)
        downloads[m.id] = nil
    }

    func isPaused(_ m: ModelInfo) -> Bool { downloads[m.id]?.paused == true }

    func delete(_ m: ModelInfo) {
        if activeModelID == m.id { engine.unload(); setActive(nil) }
        try? FileManager.default.removeItem(at: fileURL(for: m))
        refreshInstalled()
    }

    func cleanPartialDownloads() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll(); resumeData.removeAll(); downloads.removeAll(); attempts.removeAll()
        let tmp = FileManager.default.temporaryDirectory
        for f in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
        for f in (try? FileManager.default.contentsOfDirectory(at: Self.resumeDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
    }

    func importModel(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == "gguf" else { throw ToolError("الملف يجب أن يكون بصيغة GGUF") }
        let info = GGUFInspector.inspect(url)
        guard GGUFInspector.looksLikeGGUF(url), info.fileSize > 1_000_000 else {
            let reason = info.problems.first ?? "الملف لا يبدأ بترويسة GGUF"
            throw ToolError("تعذّر استيراد \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))): \(reason)")
        }
        let free = Self.freeSpace()
        if free > 0, info.fileSize + 200_000_000 > free {
            let need = ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file)
            let have = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            throw ToolError("المساحة غير كافية: الحجم \(need) والمتاح \(have).")
        }

        let dest = Self.modelsDirectory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }

        // Files from iCloud Drive and third-party providers need coordination;
        // a plain copyItem can fail with "operation not permitted" while the
        // placeholder is still being materialised.
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { readURL in
            do { try FileManager.default.copyItem(at: readURL, to: dest) }
            catch { copyError = error }
        }
        if let failure = coordError ?? copyError {
            throw ToolError("فشل نسخ الملف من المزوّد: \(failure.localizedDescription)")
        }
        refreshInstalled()
    }

    // MARK: Load

    func setActive(_ id: String?) {
        activeModelID = id
        UserDefaults.standard.set(id, forKey: "activeModelID")
    }

    func load(_ m: ModelInfo, contextLength: Int) async {
        guard !isLoading else { return }
        let verdict = DeviceCapacity.verdict(for: m)
        if verdict == .tooBig && !UserDefaults.standard.bool(forKey: "ignoreMemoryCheck") {
            lastError = "هذا النموذج لا يناسب جهازك: يحتاج تقريباً "
                + ByteCountFormatter.string(fromByteCount: DeviceCapacity.peakBytes(forWeights: m.sizeBytes), countStyle: .memory)
                + " والمتاح " + DeviceCapacity.budgetDescription
                + ". جرّب قياساً أصغر (Q4 بدل Q8).\nيمكنك تجاوز الفحص من الإعدادات على مسؤوليتك."
            return
        }
        isLoading = true
        lastError = nil
        let path = fileURL(for: m).path
        guard GGUFInspector.looksLikeGGUF(fileURL(for: m)) else {
            lastError = "الملف ليس GGUF صالحاً — أعد تحميل النموذج."
            isLoading = false
            return
        }
        let ctx = min(contextLength, m.contextLength)
        let engine = self.engine
        do {
            try await Task.detached(priority: .userInitiated) {
                try engine.load(path: path, contextLength: ctx)
            }.value
            setActive(m.id)
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    /// Loads the last active model at launch.
    func restoreActive(contextLength: Int) async {
        guard !engine.isReady, let m = activeModel else { return }
        await load(m, contextLength: contextLength)
    }

    func unload() {
        engine.unload()
        objectWillChange.send()
    }

    // MARK: - Space

    private func spaceProblem(for m: ModelInfo) -> String? {
        guard m.sizeBytes > 0 else { return nil }
        let free = Self.freeSpace()
        guard free > 0 else { return nil }
        let needed = m.sizeBytes + 400_000_000
        guard free < needed else { return nil }
        return "المساحة غير كافية: يحتاج \(needed.fileSize) والمتاح \(free.fileSize). "
            + "أفرغ مساحة ثم أعد المحاولة — التحميل لا يبدأ بمساحة أقل من الحجم + 400 م.ب."
    }

    // MARK: - Resume data (survives an app kill)

    private func resumeURL(_ id: String) -> URL {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "model"
        return Self.resumeDirectory.appendingPathComponent(safe + ".resume")
    }

    private func loadResumeData(_ id: String) -> Data? {
        if let d = resumeData[id] { return d }
        let url = resumeURL(id)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < Self.resumeMaxAge,
              let d = try? Data(contentsOf: url), !d.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        resumeData[id] = d
        return d
    }

    private func persistResumeData(_ data: Data?, for id: String) {
        guard let data, !data.isEmpty else { return }
        resumeData[id] = data
        try? data.write(to: resumeURL(id), options: .atomic)
    }

    private func clearResumeData(_ id: String) {
        resumeData[id] = nil
        try? FileManager.default.removeItem(at: resumeURL(id))
    }

    // MARK: - Retry

    /// Records a failed attempt and either schedules a backoff retry or shows
    /// the final, human-readable reason.
    private func scheduleRetry(id: String, reason: String, retryable: Bool) {
        guard let m = registered[id] ?? ModelCatalog.model(id: id) else { return }
        let attempt = (attempts[id] ?? 0) + 1
        attempts[id] = attempt
        var st = downloads[id] ?? DownloadState(total: m.sizeBytes)
        st.attempt = attempt
        st.maxAttempts = Self.maxAttempts
        st.paused = false

        if retryable, attempt < Self.maxAttempts {
            st.failed = nil
            st.retrying = "\(reason) · أعيد المحاولة \(attempt)/\(Self.maxAttempts - 1)"
            downloads[id] = st
            let delay = Self.retryDelay(attempt: attempt)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.downloads[id] != nil, self.tasks[id] == nil else { return }
                guard self.downloads[id]?.failed == nil else { return }
                self.startTask(m)
            }
        } else {
            st.retrying = nil
            st.failed = attempt > 1 ? "\(reason) — توقفت بعد \(attempt) محاولات." : reason
            downloads[id] = st
            clearResumeData(id)
            resumed.remove(id)
        }
    }

    private static func retryDelay(attempt: Int) -> Double {
        let base = 1.5 * pow(2, Double(max(0, attempt - 1)))
        return min(30, base * Double.random(in: 0.85...1.25))
    }

    private static func isRetryable(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorResourceUnavailable,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff:
            return true
        default:
            return false
        }
    }

    private static func isRetryableStatus(_ status: Int) -> Bool {
        status == 408 || status == 425 || status == 429 || (500...599).contains(status)
    }

    private static func httpMessage(_ status: Int) -> String {
        switch status {
        case 401, 403:
            return "رفض Hugging Face الطلب (\(status)) — المستودع محمي أو يحتاج توكن وصول."
        case 404:
            return "الملف غير موجود على Hugging Face (404) — تحقق من اسم المستودع والملف."
        case 416:
            return "استئناف غير صالح (416) — سأبدأ التحميل من جديد."
        case 429:
            return "طلبات كثيرة على Hugging Face (429) — الخادم يحدّ الطلبات غير المسجّلة."
        case 500...599:
            return "خطأ مؤقت في خادم Hugging Face (\(status))."
        default:
            return "فشل التحميل (HTTP \(status))."
        }
    }

    /// Turns an NSURLError into something a person can act on.
    private static func describe(_ error: NSError) -> String {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorTimedOut:
                return "انتهت مهلة الاتصال (90 ثانية بلا بيانات) — الشبكة بطيئة أو محجوبة."
            case NSURLErrorNetworkConnectionLost:
                return "انقطع الاتصال أثناء التحميل."
            case NSURLErrorNotConnectedToInternet:
                return "لا يوجد اتصال بالإنترنت."
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "تعذّر الوصول إلى huggingface.co — تحقق من الشبكة أو جرّب DNS آخر."
            case NSURLErrorCannotConnectToHost:
                return "تعذّر الاتصال بخادم Hugging Face."
            case NSURLErrorDataNotAllowed:
                return "الشبكة الحالية لا تسمح بالتحميل (بيانات الجوال مقيدة)."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return "فشل الاتصال الآمن — قد تكون الشبكة تعترض TLS."
            case NSURLErrorCancelled:
                return "أُلغي التحميل."
            default:
                return "خطأ شبكة (\(error.code)): \(error.localizedDescription)"
            }
        }
        return error.localizedDescription
    }

    // MARK: - App lifecycle

    /// Saves progress when the app leaves the foreground instead of letting
    /// iOS kill the transfer mid-file.
    private func observeLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pauseForBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterBackground() }
        })
    }

    private func pauseForBackground() {
        for id in Array(tasks.keys) {
            guard let m = knownModel(id) else { continue }
            autoPaused.insert(id)
            pause(m)
        }
    }

    private func resumeAfterBackground() {
        let ids = autoPaused
        autoPaused.removeAll()
        for id in ids {
            guard let m = knownModel(id), isPaused(m) else { continue }
            download(m)
        }
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskDescription ?? ""
        MainActor.assumeIsolated {
            var st = downloads[id] ?? DownloadState()
            st.received = totalBytesWritten
            if totalBytesExpectedToWrite > 0, totalBytesExpectedToWrite >= totalBytesWritten {
                st.total = totalBytesExpectedToWrite
            }
            let now = Date()
            if let (t, b) = lastProgressAt[id] {
                let dt = now.timeIntervalSince(t)
                if dt >= 1 {
                    st.bytesPerSecond = Double(totalBytesWritten - b) / dt
                    lastProgressAt[id] = (now, totalBytesWritten)
                }
            } else {
                lastProgressAt[id] = (now, totalBytesWritten)
            }
            downloads[id] = st
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskDescription ?? ""
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        // Must move synchronously before this method returns.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        let moved = (try? FileManager.default.moveItem(at: location, to: staged)) != nil
        MainActor.assumeIsolated {
            tasks[id] = nil
            guard let m = registered[id] ?? ModelCatalog.model(id: id) else {
                try? FileManager.default.removeItem(at: staged)
                return
            }

            // A stale resume can point at an expired signed CDN URL. Drop it and
            // start over instead of retrying the same doomed offset.
            if (status == 416 || status == 403) && resumed.contains(id) {
                clearResumeData(id)
                resumed.remove(id)
                if moved { try? FileManager.default.removeItem(at: staged) }
                scheduleRetry(id: id, reason: "انتهت صلاحية الاستئناف — أبدأ من جديد", retryable: true)
                return
            }

            guard moved else {
                scheduleRetry(id: id, reason: "تعذّر حفظ الملف المؤقت على الجهاز", retryable: true)
                return
            }
            guard (200..<300).contains(status) else {
                try? FileManager.default.removeItem(at: staged)
                scheduleRetry(id: id, reason: Self.httpMessage(status), retryable: Self.isRetryableStatus(status))
                return
            }

            let info = GGUFInspector.inspect(staged)
            guard GGUFInspector.looksLikeGGUF(staged), info.fileSize > 1_000_000 else {
                try? FileManager.default.removeItem(at: staged)
                let size = ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file)
                scheduleRetry(id: id, reason: "التنزيل غير مكتمل أو ليس GGUF (\(size))", retryable: true)
                return
            }
            // The catalog's byte count is approximate (0.1–0.3 % off), so a
            // short file is only "truncated" below 98 % of the expected size.
            if m.sizeBytes > 0, info.fileSize < Int64(Double(m.sizeBytes) * 0.98) {
                try? FileManager.default.removeItem(at: staged)
                scheduleRetry(id: id,
                              reason: "الملف ناقص: وصل \(info.fileSize.fileSize) من \(m.sizeBytes.fileSize)",
                              retryable: true)
                return
            }

            let dest = fileURL(for: m)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: staged, to: dest)
                attempts[id] = nil
                resumed.remove(id)
                clearResumeData(id)
                downloads[id] = nil
                refreshInstalled()
                if let installed = installed.first(where: { $0.fileName == m.fileName }) { setActive(installed.id) }
            } catch {
                try? FileManager.default.removeItem(at: staged)
                scheduleRetry(id: id, reason: "تعذّر نقل الملف: \(error.localizedDescription)", retryable: false)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskDescription ?? ""
        let ns = error as NSError
        let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
        MainActor.assumeIsolated {
            tasks[id] = nil
            // Pause/cancel already set the state; don't turn it into a failure.
            guard !cancelled else { return }
            if let data { persistResumeData(data, for: id) }
            scheduleRetry(id: id, reason: Self.describe(ns), retryable: Self.isRetryable(ns))
        }
    }
}
