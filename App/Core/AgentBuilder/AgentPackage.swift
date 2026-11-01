import Foundation

/// Versioned, portable agent definition. `schemaVersion` guards future migrations.
public struct AgentPackage: Codable, Identifiable, Hashable, Sendable {
    public static let currentSchema = 3

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var summary: String
    public var instructions: String
    public var icon: String
    /// "local" or a cloud provider id.
    public var modelRef: String
    public var personaID: String
    public var tools: [String]
    public var skillIDs: [String]
    public var mcpServerIDs: [String]
    public var maxSteps: Int
    public var maxTokens: Int
    public var temperature: Double
    public var offlineOnly: Bool
    public var allowNetwork: Bool
    public var allowFileWrite: Bool
    public var memoryEnabled: Bool
    public var version: String
    public var builtIn: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, summary: String = "", instructions: String = "",
                icon: String = "wand.and.stars", modelRef: String = "local", personaID: String = "general",
                tools: [String] = ["*"], skillIDs: [String] = [], mcpServerIDs: [String] = [],
                maxSteps: Int = 8, maxTokens: Int = 768, temperature: Double = 0.3,
                offlineOnly: Bool = true, allowNetwork: Bool = false, allowFileWrite: Bool = true,
                memoryEnabled: Bool = true, version: String = "1.0.0", builtIn: Bool = false,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.schemaVersion = Self.currentSchema
        self.id = id; self.name = name; self.summary = summary; self.instructions = instructions
        self.icon = icon; self.modelRef = modelRef; self.personaID = personaID
        self.tools = tools; self.skillIDs = skillIDs; self.mcpServerIDs = mcpServerIDs
        self.maxSteps = maxSteps; self.maxTokens = maxTokens; self.temperature = temperature
        self.offlineOnly = offlineOnly; self.allowNetwork = allowNetwork; self.allowFileWrite = allowFileWrite
        self.memoryEnabled = memoryEnabled; self.version = version; self.builtIn = builtIn
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public var slug: String { SkillParser.slug(name.isEmpty ? id : name) }

    public func profile() -> AgentProfile {
        AgentProfile(id: id, name: name, icon: icon, summary: summary, instructions: instructions,
                     toolNames: tools, maxSteps: maxSteps, builtIn: builtIn)
    }

    public var generation: GenerationSettings {
        var s = GenerationSettings()
        s.temperature = temperature
        s.maxTokens = maxTokens
        return s
    }

    // MARK: Markdown

    public func markdown() -> String {
        var md = "# \(name)\n\n"
        if !summary.isEmpty { md += "> \(summary)\n\n" }
        md += instructions
        md += "\n\n---\n\n"
        md += "- version: \(version)\n- tools: \(tools.joined(separator: ", "))\n"
        if !skillIDs.isEmpty { md += "- skills: \(skillIDs.joined(separator: ", "))\n" }
        return md
    }

    /// Parses `agent.md` when `config.json` is missing (human-authored packages).
    public static func fromMarkdown(_ text: String, id: String, name fallback: String) -> AgentPackage {
        let title = text.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? fallback
        return AgentPackage(id: id, name: title.trimmingCharacters(in: .whitespaces),
                            summary: String(text.prefix(160)), instructions: text)
    }
}

public enum AgentPackageError: LocalizedError {
    case missingConfig
    case unsupportedSchema(Int)
    case emptyName
    case duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfig: return "الحزمة لا تحتوي config.json ولا agent.md"
        case .unsupportedSchema(let v): return "إصدار حزمة غير مدعوم: \(v). المدعوم حتى \(AgentPackage.currentSchema)."
        case .emptyName: return "اسم الوكيل مطلوب."
        case .duplicateName(let n): return "يوجد وكيل بنفس الاسم: \(n)"
        }
    }
}

public final class AgentPackageStore {
    public static let shared = AgentPackageStore(fileName: "agents3.json")
    private let fileName: String?
    private let lock = NSLock()
    private var items: [AgentPackage]

    public init(fileName: String?) {
        self.fileName = fileName
        let loaded = fileName.flatMap { Storage.load([AgentPackage].self, from: $0) } ?? []
        let ids = Set(loaded.map(\.id))
        items = loaded + AgentPackageStore.builtIns.filter { !ids.contains($0.id) }
        if loaded.isEmpty { persist() }
    }

    public var all: [AgentPackage] { lock.lock(); defer { lock.unlock() }; return items }
    public func agent(id: String) -> AgentPackage? { all.first { $0.id == id } }

    @discardableResult
    public func upsert(_ agent: AgentPackage) throws -> AgentPackage {
        guard !agent.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw AgentPackageError.emptyName }
        var a = agent
        a.updatedAt = Date()
        a.schemaVersion = AgentPackage.currentSchema

        // Never overwrite credentials or another agent's workspace: only the package moves.
        lock.lock()
        if let i = items.firstIndex(where: { $0.id == a.id }) { items[i] = a } else { items.append(a) }
        lock.unlock()
        persist()
        return a
    }

    @discardableResult
    public func duplicate(_ id: String) -> AgentPackage? {
        guard var copy = agent(id: id) else { return nil }
        copy.id = UUID().uuidString
        copy.name += " (نسخة)"
        copy.builtIn = false
        copy.createdAt = Date()
        copy.updatedAt = Date()
        return try? upsert(copy)
    }

    public func delete(_ id: String) {
        lock.lock()
        items.removeAll { $0.id == id && !$0.builtIn }
        lock.unlock()
        persist()
    }

    public func move(_ id: String, to index: Int) {
        lock.lock()
        guard let i = items.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        let item = items.remove(at: i)
        items.insert(item, at: max(0, min(items.count, index)))
        lock.unlock()
        persist()
    }

    // MARK: Import / export

    /// Writes a `.sanadagent` ZIP: config.json, agent.md, tools.json, plus the agent workspace.
    public func export(_ id: String) throws -> URL {
        guard let a = agent(id: id) else { throw AgentPackageError.missingConfig }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        var entries: [(String, Data)] = []
        entries.append(("config.json", try encoder.encode(a)))
        entries.append(("agent.md", Data(a.markdown().utf8)))

        let toolsDoc: [String: Any] = [
            "tools": a.tools,
            "skills": a.skillIDs,
            "userTools": UserToolStore.shared.all.filter { a.tools.contains($0.name) }.map(\.name)
        ]
        if let d = try? JSONSerialization.data(withJSONObject: toolsDoc, options: [.prettyPrinted]) {
            entries.append(("tools.json", d))
        }

        let folder = WorkspaceStore.shared.folder(for: a.id)
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let u as URL in walker {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let rel = u.path.replacingOccurrences(of: folder.path + "/", with: "")
                if let d = try? Data(contentsOf: u) { entries.append(("workspace/" + rel, d)) }
            }
        }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent(a.slug + ".sanadagent.zip")
        try? FileManager.default.removeItem(at: out)
        try ZipWriter.write(entries: entries, to: out)
        return out
    }

    /// Imports a `.zip` package or a folder containing config.json / agent.md.
    @discardableResult
    public func importPackage(from url: URL) throws -> AgentPackage {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var configData: Data?
        var markdown: String?
        var workspaceFiles: [(String, Data)] = []
        var folderName = url.deletingPathExtension().lastPathComponent

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            folderName = url.lastPathComponent
            configData = try? Data(contentsOf: url.appendingPathComponent("config.json"))
            markdown = try? String(contentsOf: url.appendingPathComponent("agent.md"), encoding: .utf8)
            let ws = url.appendingPathComponent("workspace", isDirectory: true)
            if let walker = FileManager.default.enumerator(at: ws, includingPropertiesForKeys: nil) {
                for case let f as URL in walker {
                    var d: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: f.path, isDirectory: &d), !d.boolValue else { continue }
                    let rel = f.path.replacingOccurrences(of: ws.path + "/", with: "")
                    if let data = try? Data(contentsOf: f) { workspaceFiles.append((rel, data)) }
                }
            }
        } else {
            for entry in try ZipReader.read(url) {
                let path = entry.path
                if path == "config.json" { configData = entry.data }
                else if path == "agent.md" { markdown = String(decoding: entry.data, as: UTF8.self) }
                else if path.hasPrefix("workspace/") { workspaceFiles.append((String(path.dropFirst("workspace/".count)), entry.data)) }
            }
        }

        var agent: AgentPackage
        if let configData {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(AgentPackage.self, from: configData) {
                agent = decoded
            } else if let legacy = try? JSONDecoder().decode(AgentPackage.self, from: configData) {
                agent = legacy
            } else {
                throw AgentPackageError.missingConfig
            }
            if agent.schemaVersion > AgentPackage.currentSchema { throw AgentPackageError.unsupportedSchema(agent.schemaVersion) }
        } else if let markdown {
            agent = AgentPackage.fromMarkdown(markdown, id: UUID().uuidString, name: folderName)
        } else {
            throw AgentPackageError.missingConfig
        }

        agent.id = UUID().uuidString   // never collide with an existing agent
        agent.builtIn = false
        agent.createdAt = Date()
        agent.updatedAt = Date()
        let installed = try upsert(agent)

        for (rel, data) in workspaceFiles {
            if let safe = try? WorkspaceStore.shared.url(installed.id, rel) {
                try? FileManager.default.createDirectory(at: safe.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: safe)
            }
        }
        return installed
    }

    private func persist() { if let f = fileName { Storage.save(all, to: f) } }

    // MARK: Built-ins

    public static let builtIns: [AgentPackage] = [
        AgentPackage(id: "sanad3", name: "سَنَد الشامل", summary: "وكيل عام يخطط وينفّذ بكل الأدوات",
                     instructions: "أنت وكيل عام. قسّم المهمة، استخدم الأدوات للمعلومة الدقيقة، واحفظ الحقائق الدائمة في الذاكرة.",
                     icon: "wand.and.stars", tools: ["*"], maxSteps: 10, allowNetwork: false, builtIn: true),
        AgentPackage(id: "builder3", name: "بنّاء التطبيقات", summary: "ينشئ ملفات مشاريع ويصدّرها ZIP",
                     instructions: """
                     أنت مهندس برمجيات. لأي طلب: أنشئ هيكل المشروع في مساحة العمل عبر workspace_mkdir و workspace_write، \
                     اكتب ملفات كاملة قابلة للقراءة، ثم اذكر شجرة الملفات. لا تدّعي أنك جمّعت المشروع.
                     """,
                     icon: "hammer", tools: ["workspace_*", "run_javascript", "notes_add"], maxSteps: 14, builtIn: true),
        AgentPackage(id: "researcher3", name: "باحث موثّق", summary: "بحث ويب متعدد المصادر مع مراجع",
                     instructions: "ابحث بثلاث صيغ، اقرأ المصادر كاملة، ثم اكتب تقريراً بمراجع مرقمة.",
                     icon: "sparkle.magnifyingglass", tools: ["web_search", "fetch_url", "workspace_write", "notes_add"],
                     maxSteps: 14, allowNetwork: true, builtIn: true),
        AgentPackage(id: "analyst3", name: "محلل بيانات", summary: "تحليل عبر JavaScript مع جداول",
                     instructions: "لا تحسب ذهنياً. نفّذ الكود، اطبع النتائج، وفسّرها في جدول Markdown.",
                     icon: "chart.xyaxis.line", tools: ["run_javascript", "calculator", "workspace_read", "workspace_write"],
                     maxSteps: 10, builtIn: true),
        AgentPackage(id: "finance3", name: "المستشار المالي", summary: "زكاة وضريبة ونهاية خدمة",
                     instructions: "استخدم أدوات الحساب فقط، واذكر المرجع الرسمي في كل إجابة مالية.",
                     icon: "banknote", tools: ["zakat", "vat", "end_of_service", "calculator", "hijri_date"],
                     maxSteps: 8, builtIn: true),
    ]
}
