import SwiftUI
import UniformTypeIdentifiers

struct ModelsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: AppSettings
    @State private var segment = 0
    @State private var importing = false

    var ram: String { Int64(ModelManager.physicalMemory).fileSize }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("", selection: $segment) {
                        Text("نماذجي").tag(0)
                        Text("اكتشف").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                if let e = models.lastError {
                    Section { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote) }
                }
                if segment == 0 { mine } else { discover }
            }
            .navigationTitle("النماذج")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { importing = true } label: { Label("استيراد GGUF من الملفات", systemImage: "square.and.arrow.down") }
                        Button(role: .destructive) { models.cleanPartialDownloads() } label: { Label("تنظيف التحميلات الناقصة", systemImage: "trash") }
                        if state.engineReady {
                            Button { models.unload() } label: { Label("إلغاء تحميل النموذج من الذاكرة", systemImage: "eject") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data, .data]) { r in
                if case .success(let url) = r {
                    do { try models.importModel(from: url) } catch { models.lastError = error.localizedDescription }
                }
            }
            .onAppear { if models.installed.isEmpty { segment = 1 } }
        }
    }

    @ViewBuilder var mine: some View {
        Section {
            HStack {
                Label("ذاكرة الجهاز", systemImage: "memorychip")
                Spacer()
                Text(ram).foregroundStyle(.secondary)
            }
            if let m = models.activeModel, state.engineReady {
                HStack {
                    Label("النموذج النشط", systemImage: "bolt.fill").foregroundStyle(.green)
                    Spacer()
                    Text(m.name).foregroundStyle(.secondary)
                }
            }
        }
        if models.installed.isEmpty {
            EmptyStateView(icon: "cpu", title: "لا توجد نماذج بعد",
                           message: "حمّل نموذجاً من «اكتشف». ننصح بـ \(ModelCatalog.recommended(forMemory: ModelManager.physicalMemory).name) لجهازك.",
                           action: ("اكتشف النماذج", { segment = 1 }))
                .listRowBackground(Color.clear)
        } else {
            Section("المثبّتة") {
                ForEach(models.installed) { m in
                    InstalledModelRow(model: m)
                }
            }
        }
    }

    @ViewBuilder var discover: some View {
        let rec = ModelCatalog.recommended(forMemory: ModelManager.physicalMemory)
        Section {
            Text("كل النماذج تعمل على جهازك بعد تحميلها. الأحجام تقريبية، والسرعة تعتمد على جهازك. الموصى به لجهازك (\(ram)): \(rec.name).")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section("المكتبة") {
            ForEach(ModelCatalog.models) { m in
                CatalogRow(model: m, recommended: m.id == rec.id)
            }
        }
    }
}

struct InstalledModelRow: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: AppSettings
    let model: ModelInfo

    var isActive: Bool { models.activeModelID == model.id && state.engineReady }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name).font(.headline)
                Text("\(model.publisher) · \(model.sizeBytes.fileSize)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Label("نشط", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.subheadline)
            } else if models.isLoading {
                ProgressView()
            } else {
                Button("تشغيل") { Task { await models.load(model, contextLength: settings.generation.contextLength) } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .swipeActions {
            Button(role: .destructive) { models.delete(model) } label: { Label("حذف", systemImage: "trash") }
        }
    }
}

struct CatalogRow: View {
    @EnvironmentObject var models: ModelManager
    let model: ModelInfo
    let recommended: Bool

    var fits: Bool { ModelCatalog.fits(model, memory: ModelManager.physicalMemory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name).font(.headline)
                        if recommended { Image(systemName: "star.fill").foregroundStyle(Color("Gold")).font(.caption) }
                    }
                    Text("\(model.publisher) · \(model.parameters) · \(model.sizeBytes.fileSize)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                action
            }
            Text(model.summary).font(.footnote).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack { ForEach(model.badges, id: \.self) { BadgeView(badge: $0) } }
            }
            if !fits {
                Label("قد لا تكفي ذاكرة جهازك لهذا النموذج", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
            }
            if let d = models.downloads[model.id] {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: d.fraction)
                    HStack {
                        Text("\(d.received.fileSize) / \(d.total.fileSize)")
                        Spacer()
                        if d.bytesPerSecond > 0 { Text("\(Int64(d.bytesPerSecond).fileSize)/ث") }
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if let f = d.failed { Text(f).font(.caption2).foregroundStyle(.red) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder var action: some View {
        if models.isInstalled(model) {
            Label("مثبّت", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        } else if let d = models.downloads[model.id], d.failed == nil, !models.isPaused(model) {
            Menu {
                Button { models.pause(model) } label: { Label("إيقاف مؤقت", systemImage: "pause") }
                Button(role: .destructive) { models.cancel(model) } label: { Label("إلغاء", systemImage: "xmark") }
            } label: {
                Text("\(Int(d.fraction * 100))%").font(.caption.monospacedDigit().bold())
            }
        } else if models.isPaused(model) || models.downloads[model.id]?.failed != nil {
            Button("استئناف") { models.download(model) }.buttonStyle(.bordered).controlSize(.small)
        } else {
            Button { models.download(model) } label: { Label("تحميل", systemImage: "arrow.down.circle") }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }
}
