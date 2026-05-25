import UIKit
import Combine
import CmuxKit

/// Catalog of app-level UIKeyCommands that appear in iPadOS 26's
/// hardware-keyboard menu HUD and route through `KeyboardShortcutBus` so
/// SwiftUI views can react.
///
/// **Important contract**: SwiftTerm consumes typing-relevant keys
/// (alphanumerics, control sequences, Option-as-Meta) inside the terminal
/// view's `pressesBegan`. We only register here the chords that are
/// genuinely app-level (palette, surface switching, jump-to-unread). Any key
/// without a Cmd modifier is reserved for the focused terminal surface.
@MainActor
enum KeyboardShortcutCatalog {

    enum Action: String, CaseIterable {
        case commandPalette = "cmuxCommandPalette:"
        case jumpToUnread = "cmuxJumpToUnread:"
        case nextSurface = "cmuxNextSurface:"
        case previousSurface = "cmuxPreviousSurface:"
        case nextWorkspace = "cmuxNextWorkspace:"
        case previousWorkspace = "cmuxPreviousWorkspace:"
        case markAllRead = "cmuxMarkAllRead:"
        case toggleSidebar = "cmuxToggleSidebar:"
        case newWorkspace = "cmuxNewWorkspace:"
        case escapePalette = "cmuxEscapePalette:"

        var selector: Selector { Selector(rawValue) }
    }

    static func appLevelCommands() -> [UIKeyCommand] {
        let commands: [UIKeyCommand] = [
            command(title: L10n.string("shortcut.command_palette", defaultValue: "Command Palette"), action: .commandPalette,
                    input: "p", modifierFlags: [.command]),
            command(title: L10n.string("shortcut.jump_to_unread", defaultValue: "Jump to unread notification"), action: .jumpToUnread,
                    input: "u", modifierFlags: [.command, .shift]),
            command(title: L10n.string("shortcut.next_surface", defaultValue: "Next surface"), action: .nextSurface,
                    input: "]", modifierFlags: [.command]),
            command(title: L10n.string("shortcut.previous_surface", defaultValue: "Previous surface"), action: .previousSurface,
                    input: "[", modifierFlags: [.command]),
            command(title: L10n.string("shortcut.next_workspace", defaultValue: "Next workspace"), action: .nextWorkspace,
                    input: "\t", modifierFlags: [.command]),
            command(title: L10n.string("shortcut.previous_workspace", defaultValue: "Previous workspace"), action: .previousWorkspace,
                    input: "\t", modifierFlags: [.command, .shift]),
            command(title: L10n.string("shortcut.mark_all_read", defaultValue: "Mark all read"), action: .markAllRead,
                    input: "u", modifierFlags: [.command]),
            command(title: L10n.string("shortcut.toggle_sidebar", defaultValue: "Toggle sidebar"), action: .toggleSidebar,
                    input: "0", modifierFlags: [.command]),
            command(title: L10n.string("shortcut.new_workspace", defaultValue: "New workspace"), action: .newWorkspace,
                    input: "n", modifierFlags: [.command]),
            UIKeyCommand(title: L10n.string("shortcut.close_palette", defaultValue: "Close palette"),
                         action: Action.escapePalette.selector,
                         input: UIKeyCommand.inputEscape)
        ]
        for command in commands {
            command.wantsPriorityOverSystemBehavior = false
        }
        return commands
    }

    private static func command(
        title: String,
        action: Action,
        input: String,
        modifierFlags: UIKeyModifierFlags
    ) -> UIKeyCommand {
        UIKeyCommand(
            title: title,
            action: action.selector,
            input: input,
            modifierFlags: modifierFlags,
            discoverabilityTitle: title
        )
    }

    static func handles(_ action: Selector) -> Bool {
        Action.allCases.contains(where: { $0.selector == action })
    }

    static func installMenu(into builder: any UIMenuBuilder) {
        let palette = UIKeyCommand(
            title: L10n.string("shortcut.command_palette", defaultValue: "Command Palette"),
            action: Action.commandPalette.selector,
            input: "p", modifierFlags: [.command],
            discoverabilityTitle: L10n.string("shortcut.command_palette", defaultValue: "Command Palette")
        )
        let jump = UIKeyCommand(
            title: L10n.string("shortcut.jump_to_unread.short", defaultValue: "Jump to Unread"),
            action: Action.jumpToUnread.selector,
            input: "u", modifierFlags: [.command, .shift]
        )
        let group = UIMenu(title: L10n.string("app.short_name", defaultValue: "cmux"),
                           image: nil,
                           identifier: UIMenu.Identifier("com.cmuxterm.remote.menu"),
                           options: [],
                           children: [palette, jump])
        builder.insertSibling(group, beforeMenu: .help)
    }
}

@MainActor
final class KeyboardShortcutBus: ObservableObject {
    static let shared = KeyboardShortcutBus()

    let actions = PassthroughSubject<KeyboardShortcutCatalog.Action, Never>()

    func dispatch(_ action: KeyboardShortcutCatalog.Action) {
        actions.send(action)
    }
}

// MARK: - Responder-chain hooks

extension CmuxRemoteAppDelegate {
    @objc func cmuxCommandPalette(_ sender: Any?) { KeyboardShortcutBus.shared.dispatch(.commandPalette) }
    @objc func cmuxJumpToUnread(_ sender: Any?) { KeyboardShortcutBus.shared.dispatch(.jumpToUnread) }
    @objc func cmuxNextSurface(_ sender: Any?) { KeyboardShortcutBus.shared.dispatch(.nextSurface) }
    @objc func cmuxPreviousSurface(_ sender: Any?) { KeyboardShortcutBus.shared.dispatch(.previousSurface) }
    @objc func cmuxNextWorkspace(_ sender: Any?) { KeyboardShortcutBus.shared.dispatch(.nextWorkspace) }
    @objc func cmuxPreviousWorkspace(_ sender: Any?) { KeyboardShortcutBus.shared.dispatch(.previousWorkspace) }
    @objc func cmuxMarkAllRead(_ sender: Any?) { KeyboardShortcutBus.shared.dispatch(.markAllRead) }
    @objc func cmuxToggleSidebar(_ sender: Any?) { KeyboardShortcutBus.shared.dispatch(.toggleSidebar) }
    @objc func cmuxNewWorkspace(_ sender: Any?) { KeyboardShortcutBus.shared.dispatch(.newWorkspace) }
    @objc func cmuxEscapePalette(_ sender: Any?) { KeyboardShortcutBus.shared.dispatch(.escapePalette) }
}
