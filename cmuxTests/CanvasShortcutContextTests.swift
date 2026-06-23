import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Canvas shortcut context")
struct CanvasShortcutContextTests {
    @Test
    func canvasOnlyShortcutDefaultWhenClausesRequireCanvasLayout() {
        var splitContext = ShortcutFocusState(browser: false, markdown: false, sidebar: false).context
        splitContext.setBool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue, false)

        var canvasContext = ShortcutFocusState(browser: false, markdown: false, sidebar: false).context
        canvasContext.setBool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue, true)

        #expect(
            KeyboardShortcutSettings.effectiveWhenClause(for: .toggleCanvasLayout).evaluate(splitContext),
            "The layout toggle must stay available outside canvas mode"
        )

        for action in KeyboardShortcutSettings.Action.canvasActions where action != .toggleCanvasLayout {
            let clause = KeyboardShortcutSettings.effectiveWhenClause(for: action)
            #expect(
                !clause.evaluate(splitContext),
                "\(action.rawValue) must not claim its shortcut while the workspace uses split layout"
            )
            #expect(
                clause.evaluate(canvasContext),
                "\(action.rawValue) must be available when the workspace uses canvas layout"
            )
        }
    }
}
