import SwiftUI

/// The chat tab: one conversation, open immediately — no list in the way.
/// The list and "new chat" stay one tap away in the toolbar.
struct ChatHomeView: View {
    @EnvironmentObject var state: AppState
    @State private var current: Conversation?
    @State private var showList = false

    var body: some View {
        NavigationStack {
            Group {
                if let c = current, state.conversations.contains(where: { $0.id == c.id }) {
                    ChatView(conversation: c).id(c.id)
                } else {
                    Color.clear
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showList = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("كل المحادثات")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: newChat) {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("محادثة جديدة")
                }
            }
        }
        .sheet(isPresented: $showList) { listSheet }
        .sheet(isPresented: $state.showConversations) { listSheet }
        .onAppear(perform: openInitial)
        .onChange(of: state.pendingConversationID) { _, _ in openPendingConversation() }
        .onChange(of: state.pendingQuery) { _, _ in openPendingQuery() }
        .onChange(of: state.deepLinkScreen) { _, new in
            if new == "newChat" {
                state.deepLinkScreen = nil
                newChat()
            }
        }
        .onChange(of: state.conversations.count) { _, _ in
            // The open conversation may have been deleted from the list.
            if let c = current, !state.conversations.contains(where: { $0.id == c.id }) {
                current = nil
                openInitial()
            }
        }
    }

    var listSheet: some View {
        ConversationListSheet(
            select: { c in current = c },
            create: { newChat() }
        )
    }

    // MARK: Opening

    func openInitial() {
        if state.deepLinkScreen == "newChat" {
            state.deepLinkScreen = nil
            newChat()
            return
        }
        if state.pendingConversationID != nil { openPendingConversation(); return }
        if state.pendingQuery != nil { openPendingQuery(); return }
        guard current == nil else { return }

        if UserDefaults.standard.bool(forKey: "demo"),
           let first = state.conversations.first(where: { $0.agentID == nil }) {
            current = first
        } else if let last = state.conversations.first {
            current = last
        } else {
            newChat()
        }
    }

    func newChat() {
        if let c = current,
           let live = state.conversations.first(where: { $0.id == c.id }),
           live.messages.isEmpty {
            return
        }
        let c = Conversation(personaID: state.settings.personaID)
        state.conversations.insert(c, at: 0)
        current = c
    }

    func openPendingConversation() {
        guard let id = state.pendingConversationID else { return }
        state.pendingConversationID = nil
        guard let c = state.conversations.first(where: { $0.id == id }) else { return }
        current = c
    }

    func openPendingQuery() {
        guard let q = state.pendingQuery else { return }
        state.pendingQuery = nil
        let c = Conversation(personaID: state.settings.personaID)
        state.conversations.insert(c, at: 0)
        state.pendingAutoSend = q
        current = c
    }
}

/// The conversation list, presented as a sheet from the chat tab or from Home.
struct ConversationListSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var select: (Conversation) -> Void
    var create: () -> Void

    @State private var search = ""

    var filtered: [Conversation] {
        guard !search.isEmpty else { return state.conversations }
        let q = ArabicText.normalize(search)
        return state.conversations.filter {
            ArabicText.normalize($0.title).contains(q)
                || $0.messages.contains { ArabicText.normalize($0.content).contains(q) }
        }
    }

    struct ConvGroup: Identifiable {
        var id: String { title }
        let title: String
        let items: [Conversation]
    }

    var groups: [ConvGroup] {
        let cal = Calendar.current
        var today: [Conversation] = [], week: [Conversation] = [], older: [Conversation] = []
        for c in filtered {
            if cal.isDateInToday(c.updatedAt) { today.append(c) }
            else if c.updatedAt > Date().addingTimeInterval(-7 * 86400) { week.append(c) }
            else { older.append(c) }
        }
        return [
            ConvGroup(title: "اليوم", items: today),
            ConvGroup(title: "آخر ٧ أيام", items: week),
            ConvGroup(title: "أقدم", items: older),
        ].filter { !$0.items.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        create()
                        dismiss()
                    } label: {
                        Label("محادثة جديدة", systemImage: "square.and.pencil")
                    }
                }

                if filtered.isEmpty {
                    Section {
                        Text("لا محادثات بعد. ابدأ واحدة من هنا.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                ForEach(groups) { g in
                    Section(g.title) {
                        ForEach(g.items) { c in
                            Button {
                                select(c)
                                dismiss()
                            } label: {
                                ConversationRow(c: c)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    state.deleteConversation(c.id)
                                } label: {
                                    Label("حذف", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "ابحث في المحادثات")
            .navigationTitle("المحادثات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                }
            }
        }
    }
}
