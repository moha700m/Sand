import SwiftUI

/// Dashboard: what is loaded, what is running, and the fastest way to act.
struct HomeView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var runner: AgentRunner

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    runtimeCard
                    runningCard
                    quickActions
                    agentsSection
                    recentSection
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("سَنَد AI")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { state.tab = .chat } label: { Image(systemName: "square.and.pencil") }
                }
            }
        }
    }

    // MARK: Runtime

    var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                OrbView(size: 44, animating: models.isLoading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.engineReady ? (models.activeModel?.name ?? "نموذج محلي") : "لا يوجد نموذج محمّل")
                        .font(.headline)
                    Text(state.engineReady ? "يعمل على الجهاز · \(RuntimeRegistry.summary)" : "اختر نموذجاً للبدء")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Circle().fill(state.engineReady ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
            }

            if models.isLoading {
                ProgressView(value: 0.5)
                Text("جاري التحميل في الذاكرة…").font(.caption2).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                metric("الذاكرة", ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .file))
                metric("مساحة العمل", ByteCountFormatter.string(fromByteCount: state.workspace.totalBytes(state.workspaceContext.agentID), countStyle: .file))
                metric("النماذج", "\(models.installed.count)")
            }

            if !state.providers.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "cloud").font(.caption)
                    Text("\(state.providers.count) مزود سحابي — الوضع الحالي: \(settings.hybridMode ? "هجين" : "محلي أولاً")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Running jobs

    @ViewBuilder var runningCard: some View {
        let jobs = runner.activeJobs
        if let first = jobs.first {
            Button { state.tab = .agents } label: {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(jobs.count == 1 ? "مهمة تعمل الآن" : "\(jobs.count) مهام تعمل الآن")
                            .font(.footnote.weight(.semibold))
                        Text(first.goal).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.left").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Actions

    var quickActions: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            action("محادثة جديدة", "bubble.left.and.bubble.right.fill", .teal) {
                state.deepLinkScreen = "newChat"
                state.tab = .chat
            }
            action("النماذج", "cpu.fill", .indigo) { state.tab = .models }
            action("الوكلاء", "wand.and.stars", .purple) { state.tab = .agents }
            action("مساحة العمل", "folder.fill", .orange) { state.tab = .more; state.deepLinkScreen = "workspace" }
            action("الأدوات", "hammer.fill", .pink) { state.tab = .more; state.deepLinkScreen = "tools" }
            action("MCP", "puzzlepiece.extension.fill", .blue) { state.tab = .more; state.deepLinkScreen = "mcp" }
        }
    }

    func action(_ title: String, _ icon: String, _ color: Color, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(color, in: RoundedRectangle(cornerRadius: 9))
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                Spacer()
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: Sections

    var agentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("الوكلاء").font(.headline)
                Spacer()
                Button("عرض الكل") { state.tab = .agents }.font(.caption)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(state.packages.prefix(6)) { p in
                        Button { state.openAgent(p.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: p.icon).foregroundStyle(.tint)
                                Text(p.name).font(.footnote.weight(.semibold)).lineLimit(1)
                                Text("\(p.maxSteps) خطوة").font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(width: 120, alignment: .leading)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("آخر المحادثات").font(.headline)
                Spacer()
                Button("الكل") { state.tab = .chat }.font(.caption)
            }
            if state.conversations.isEmpty {
                Text("ابدأ محادثة — كل شيء يبقى على جهازك.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            } else {
                ForEach(state.conversations.prefix(4)) { c in
                    Button { state.openConversation(c.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bubble.left").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(.footnote.weight(.medium)).lineLimit(1)
                                Text(String(c.messages.last?.content.prefix(70) ?? "")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.left").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
