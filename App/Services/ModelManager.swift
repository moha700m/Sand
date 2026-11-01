import Foundation
import SwiftUI

/// Downloads, imports, stores and loads GGUF models.
@MainActor
final class ModelManager: NSObject, ObservableObject {
    struct DownloadState: Equatable {
        var received: Int64 = 0
        var total: Int64 = 0
        var bytesPerSecond: Double = 0
        var failed: String?
        var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
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
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        cfg.waitsForConnectivity = true
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

    static let physicalMemory = ProcessInfo.processInfo.physicalMemory

    init(engine: LlamaEngine) {
        self.engine = engine
        super.init()
        refreshInstalled()
        activeModelID = UserDefaults.standard.string(forKey: "activeModelID")
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

    // MARK: Download

    func register(_ m: ModelInfo) { registered[m.id] = m }

    func download(_ m: ModelInfo) {
        registered[m.id] = m
        guard tasks[m.id] == nil else { return }
        lastError = nil
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: m.id) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: m.downloadURL)
        }
        task.taskDescription = m.id
        tasks[m.id] = task
        downloads[m.id] = DownloadState(total: m.sizeBytes)
        task.resume()
    }

    func pause(_ m: ModelInfo) {
        tasks[m.id]?.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                if let data { self?.resumeData[m.id] = data }
                self?.tasks[m.id] = nil
            }
        })
    }

    func cancel(_ m: ModelInfo) {
        tasks[m.id]?.cancel()
        tasks[m.id] = nil
        resumeData[m.id] = nil
        downloads[m.id] = nil
    }

    func isPaused(_ m: ModelInfo) -> Bool { tasks[m.id] == nil && resumeData[m.id] != nil }

    func delete(_ m: ModelInfo) {
        if activeModelID == m.id { engine.unload(); setActive(nil) }
        try? FileManager.default.removeItem(at: fileURL(for: m))
        refreshInstalled()
    }

    func cleanPartialDownloads() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll(); resumeData.removeAll(); downloads.removeAll()
        let tmp = FileManager.default.temporaryDirectory
        for f in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
    }

    func importModel(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == "gguf" else { throw ToolError("الملف يجب أن يكون بصيغة GGUF") }
        let info = GGUFInspector.inspect(url)
        guard info.isUsable else {
            throw ToolError("ملف GGUF غير صالح: " + (info.problems.first ?? "بنية غير مكتملة"))
        }
        let dest = Self.modelsDirectory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: url, to: dest)
        refreshInstalled()
    }

    // MARK: Load

    func setActive(_ id: String?) {
        activeModelID = id
        UserDefaults.standard.set(id, forKey: "activeModelID")
    }

    func load(_ m: ModelInfo, contextLength: Int) async {
        guard !isLoading else { return }
        if !ModelCatalog.fits(m, memory: Self.physicalMemory) && !UserDefaults.standard.bool(forKey: "ignoreMemoryCheck") {
            lastError = LLMError.insufficientMemory(needed: UInt64(m.estimatedMemoryBytes),
                                                    available: UInt64(Double(Self.physicalMemory) * 0.65)).localizedDescription
                + "\nيمكنك تجاوز الفحص من الإعدادات على مسؤوليتك."
            return
        }
        isLoading = true
        lastError = nil
        let path = fileURL(for: m).path
        guard GGUFInspector.looksLikeGGUF(fileURL(for: m)) else {
            lastError = "الملف ليس GGUF صالحاً — أعد تحميل النموذج."
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
}

extension ModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskDescription ?? ""
        MainActor.assumeIsolated {
            var st = downloads[id] ?? DownloadState()
            st.received = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { st.total = totalBytesExpectedToWrite }
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
            guard let m = registered[id] ?? ModelCatalog.model(id: id) else { return }
            guard moved, status < 400 else {
                downloads[id]?.failed = "فشل التحميل (HTTP \(status))"
                return
            }
            let info = GGUFInspector.inspect(staged)
            guard info.isUsable else {
                try? FileManager.default.removeItem(at: staged)
                downloads[id]?.failed = "الملف الذي نزل ليس GGUF صالحاً: " + (info.problems.first ?? "")
                return
            }
            let dest = fileURL(for: m)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: staged, to: dest)
                downloads[id] = nil
                refreshInstalled()
                if let installed = installed.first(where: { $0.fileName == m.fileName }) { setActive(installed.id) }
            } catch {
                downloads[id]?.failed = error.localizedDescription
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskDescription ?? ""
        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        MainActor.assumeIsolated {
            tasks[id] = nil
            if let data { resumeData[id] = data }
            if !cancelled {
                downloads[id]?.failed = "انقطع التحميل — اضغط استئناف"
            }
        }
    }
}
