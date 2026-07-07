import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct WorkspaceShortcutHintVisibilityTests {
    @Test
    func hiddenWhenNoShortcutDigit() {
        let v = WorkspaceShortcutHintVisibility.resolve(
            modifierHintActive: true,
            alwaysShowsNumbers: true,
            hasLabel: false,
            closeButtonVisible: false
        )
        #expect(v.isVisible == false)
    }

    @Test
    func modifierHoldShowsAtFullStrength() {
        let v = WorkspaceShortcutHintVisibility.resolve(
            modifierHintActive: true,
            alwaysShowsNumbers: false,
            hasLabel: true,
            closeButtonVisible: false
        )
        #expect(v.isVisible == true)
        #expect(v.opacity == 1.0)
    }

    @Test
    func hiddenByDefaultWhenNeitherModifierNorPreference() {
        let v = WorkspaceShortcutHintVisibility.resolve(
            modifierHintActive: false,
            alwaysShowsNumbers: false,
            hasLabel: true,
            closeButtonVisible: false
        )
        #expect(v.isVisible == false)
    }

    @Test
    func alwaysShowPreferenceShowsDimmed() {
        let v = WorkspaceShortcutHintVisibility.resolve(
            modifierHintActive: false,
            alwaysShowsNumbers: true,
            hasLabel: true,
            closeButtonVisible: false
        )
        #expect(v.isVisible == true)
        #expect(v.opacity < 1.0)
    }

    @Test
    func persistentNumberYieldsToHoverCloseButton() {
        let v = WorkspaceShortcutHintVisibility.resolve(
            modifierHintActive: false,
            alwaysShowsNumbers: true,
            hasLabel: true,
            closeButtonVisible: true
        )
        #expect(v.isVisible == false)
    }

    @Test
    func modifierHoldStillWinsOverCloseButton() {
        // Holding ⌘ suppresses the close button elsewhere, so the number should
        // still show at full strength even if closeButtonVisible were passed true.
        let v = WorkspaceShortcutHintVisibility.resolve(
            modifierHintActive: true,
            alwaysShowsNumbers: true,
            hasLabel: true,
            closeButtonVisible: true
        )
        #expect(v.isVisible == true)
        #expect(v.opacity == 1.0)
    }
}
