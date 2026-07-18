import Foundation

/// The single dispatch table for every core cmux-lite keyboard shortcut.
public struct CmuxShortcutTable: Sendable {
    private let actions: [CmuxShortcutInput: CmuxShortcutAction]

    /// Creates the canonical shortcut map.
    public init() {
        var actions: [CmuxShortcutInput: CmuxShortcutAction] = [
            CmuxShortcutInput(key: .character("d"), modifiers: .command): .split(.right),
            CmuxShortcutInput(
                key: .character("d"),
                modifiers: [.command, .shift]
            ): .split(.down),
            CmuxShortcutInput(key: .character("t"), modifiers: .command): .newTab,
            CmuxShortcutInput(key: .character("w"), modifiers: .command): .closeTab,
            CmuxShortcutInput(key: .character("n"), modifiers: .command): .newWorkspace,
        ]
        for index in 0..<9 {
            let key = CmuxShortcutKey.character(Character(String(index + 1)))
            actions[CmuxShortcutInput(key: key, modifiers: .command)] = .selectTab(index)
            actions[CmuxShortcutInput(key: key, modifiers: .control)] = .selectScreen(index)
        }
        for direction in [
            CmuxPaneDirection.left,
            .right,
            .up,
            .down,
        ] {
            let key = CmuxShortcutKey.arrow(direction)
            actions[CmuxShortcutInput(
                key: key,
                modifiers: [.command, .option]
            )] = .focusPane(direction)
            actions[CmuxShortcutInput(
                key: key,
                modifiers: [.command, .control]
            )] = .resizePane(direction)
        }
        self.actions = actions
    }

    /// Resolves a chord through the one canonical action table.
    /// - Parameter input: A normalized platform keyboard event.
    /// - Returns: The matching action, or `nil` so the terminal can handle the key.
    public func action(for input: CmuxShortcutInput) -> CmuxShortcutAction? {
        actions[input]
    }
}
