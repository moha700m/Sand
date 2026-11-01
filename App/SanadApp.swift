import SwiftUI

@main
struct SanadApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.runner)
                .environmentObject(state.settings)
                .environmentObject(state.models)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar_SA"))
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @AppStorage("seenOnboarding") private var seenOnboarding = false

    var body: some View {
        TabView(selection: $state.tab) {
            HomeView()
                .tabItem { Label("الرئيسية", systemImage: "house.fill") }
                .tag(AppTab.home)
            ChatHomeView()
                .tabItem { Label("المحادثة", systemImage: "bubble.left.fill") }
                .tag(AppTab.chat)
            ModelsView()
                .tabItem { Label("النماذج", systemImage: "cpu") }
                .tag(AppTab.models)
            MoreView()
                .tabItem { Label("المزيد", systemImage: "square.grid.2x2.fill") }
                .tag(AppTab.more)
        }
        .tint(settings.accentColor)
        .preferredColorScheme(settings.colorScheme)
        .fullScreenCover(isPresented: Binding(get: { !seenOnboarding }, set: { if !$0 { seenOnboarding = true } })) {
            OnboardingView { seenOnboarding = true }
                .environment(\.layoutDirection, .rightToLeft)
        }
        .sheet(item: $state.pendingConfirmation) { p in
            ToolConfirmationSheet(pending: p)
                .presentationDetents([.medium])
                .interactiveDismissDisabled()
        }
        .task {
            if !UserDefaults.standard.bool(forKey: "demo") {
                Task { await state.mcp.connectAll() }
                if !state.isCloud(nil) { await state.models.restoreActive(contextLength: settings.generation.contextLength) }
            }
        }
        .onOpenURL { url in
            // sanad://ask?q=...
            if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value {
                state.tab = .chat
                state.pendingQuery = q
            }
        }
    }
}

struct ToolConfirmationSheet: View {
    @EnvironmentObject var state: AppState
    let pending: AppState.PendingConfirmation

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: pending.spec.icon)
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .padding(.top, 24)
            Text("الوكيل يطلب الإذن").font(.title2.bold())
            Text("يريد تنفيذ: \(pending.spec.title)").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pending.arguments.keys.sorted(), id: \.self) { k in
                    HStack(alignment: .top) {
                        Text(k).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Text(pending.arguments[k]?.stringValue ?? pending.arguments[k]?.compactJSON ?? "")
                            .font(.callout).multilineTextAlignment(.trailing)
                    }
                }
            }
            .padding()
            .background(Color("CardBackground"), in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 12) {
                Button(role: .cancel) { state.resolveConfirmation(false) } label: {
                    Text("رفض").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { state.resolveConfirmation(true) } label: {
                    Text("سماح").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            Spacer()
        }
        .padding(.horizontal)
    }
}
