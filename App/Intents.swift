import AppIntents
import Foundation

/// "اسأل سَنَد" from Siri, Shortcuts, Spotlight or the Action Button.
struct AskSanadIntent: AppIntent {
    static var title: LocalizedStringResource = "اسأل سَنَد"
    static var description = IntentDescription("افتح سَنَد واطرح سؤالاً في محادثة جديدة.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "السؤال")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AppStateHolder.shared?.tab = .chat
        AppStateHolder.shared?.pendingQuery = question
        return .result()
    }
}

struct StartVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "محادثة صوتية مع سَنَد"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppStateHolder.shared?.tab = .chat
        return .result()
    }
}

struct SanadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskSanadIntent(), phrases: ["اسأل \(.applicationName)", "Ask \(.applicationName)"],
                    shortTitle: "اسأل سَنَد", systemImageName: "sparkles")
        AppShortcut(intent: StartVoiceIntent(), phrases: ["كلّم \(.applicationName)", "Talk to \(.applicationName)"],
                    shortTitle: "محادثة صوتية", systemImageName: "waveform")
    }
}
