import AppIntents
import CmuxKit
import Foundation

/// App Intents: SendText, OpenWorkspace, JumpToUnread, MarkAllRead.
/// These power Siri voice commands, Spotlight, Shortcuts.app, and
/// interactive widget buttons.
struct SendTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Send text to cmux surface"
    static let openAppWhenRun: Bool = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let description = IntentDescription(
        "Sends arbitrary text to a focused cmux surface (terminal or browser).",
        categoryName: "cmux"
    )

    @Parameter(title: "Text") var text: String
    @Parameter(title: "Surface identifier (cmux ref or UUID)") var surfaceID: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !text.unicodeScalars.contains(where: { scalar in
            scalar.value < 0x20 && scalar.value != 0x09
        }) else {
            throw $text.needsValueError(IntentDialog(stringLiteral: L10n.string(
                    "intent.send_text.error.control_characters",
                    defaultValue: "Text shortcuts cannot send control characters"
                ))
            )
        }
        try await ConnectionManager.shared.performRemoteAction(action: "intent-send") { client in
            try await client.sendText(text, surfaceID: SurfaceID(surfaceID))
        }
        return .result()
    }
}

struct OpenWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Open cmux workspace"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let description = IntentDescription(
        "Focuses a workspace on the connected Mac and brings cmux to the front.",
        categoryName: "cmux"
    )

    @Parameter(title: "Workspace identifier (cmux ref or UUID)") var workspaceID: String

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ConnectionManager.shared.performRemoteAction(action: "intent-select-workspace") { client in
            try await client.selectWorkspace(WorkspaceID(workspaceID))
        }
        return .result()
    }
}

struct JumpToUnreadIntent: AppIntent {
    static let title: LocalizedStringResource = "Jump to latest unread cmux notification"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let description = IntentDescription(
        "Asks the connected Mac to focus the workspace and surface of the most recent unread notification.",
        categoryName: "cmux"
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ConnectionManager.shared.performRemoteAction(action: "intent-jump-to-unread") { client in
            try await client.jumpToUnread()
        }
        return .result()
    }
}

struct MarkAllReadIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark all cmux notifications read"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ConnectionManager.shared.performRemoteAction(action: "intent-mark-all-read") { client in
            try await client.markAllRead()
        }
        return .result()
    }
}

struct CmuxAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: JumpToUnreadIntent(),
            phrases: [
                "Jump to unread in \(.applicationName)",
                "Show the agent waiting in \(.applicationName)"
            ],
            shortTitle: "Jump to unread",
            systemImageName: "bell.badge"
        )
        AppShortcut(
            intent: MarkAllReadIntent(),
            phrases: ["Mark all \(.applicationName) notifications read"],
            shortTitle: "Mark all read",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: SendTextIntent(),
            phrases: ["Send to \(.applicationName)"],
            shortTitle: "Send text",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: OpenWorkspaceIntent(),
            phrases: ["Open workspace in \(.applicationName)"],
            shortTitle: "Open workspace",
            systemImageName: "rectangle.split.3x1"
        )
    }
}
