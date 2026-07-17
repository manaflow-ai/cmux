@testable import CmuxLiteCore
import Testing

@Suite
struct CmuxShortcutTableTests {
    private let table = CmuxShortcutTable()

    @Test
    func dispatchesCharacterShortcuts() {
        let cases: [(Character, CmuxShortcutModifiers, CmuxShortcutAction)] = [
            ("d", .command, .split(.right)),
            ("d", [.command, .shift], .split(.down)),
            ("t", .command, .newTab),
            ("w", .command, .closeTab),
            ("n", .command, .newWorkspace),
            ("4", .command, .selectTab(3)),
            ("7", .control, .selectScreen(6)),
        ]
        for (character, modifiers, expected) in cases {
            #expect(table.action(for: CmuxShortcutInput(
                key: .character(character),
                modifiers: modifiers
            )) == expected)
        }
    }

    @Test
    func dispatchesFocusArrows() {
        for direction in [
            CmuxPaneDirection.left,
            .right,
            .up,
            .down,
        ] {
            #expect(table.action(for: CmuxShortcutInput(
                key: .arrow(direction),
                modifiers: [.command, .option]
            )) == .focusPane(direction))
        }
    }

    @Test
    func dispatchesResizeArrows() {
        for direction in [
            CmuxPaneDirection.left,
            .right,
            .up,
            .down,
        ] {
            #expect(table.action(for: CmuxShortcutInput(
                key: .arrow(direction),
                modifiers: [.command, .control]
            )) == .resizePane(direction))
        }
    }

    @Test
    func leavesUnknownAndOverModifiedKeysForTheTerminal() {
        #expect(table.action(for: CmuxShortcutInput(
            key: .character("x"),
            modifiers: .command
        )) == nil)
        #expect(table.action(for: CmuxShortcutInput(
            key: .character("t"),
            modifiers: [.command, .shift]
        )) == nil)
    }
}
