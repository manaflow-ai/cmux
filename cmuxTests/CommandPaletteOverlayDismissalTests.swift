import CmuxCommandPalette
import CoreGraphics
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Which interactions close each overlay shown in the command palette layer.
@Suite struct CommandPaletteOverlayDismissalTests {
    private let outsideClick = CommandPaletteInteractionDismissal.pointer(
        CommandPalettePointerEvent(isInObservedWindow: true, locationInWindow: CGPoint(x: 4, y: 4))
    )

    @Test func findWindowStaysOpenWhenItsWindowStopsBeingKey() {
        #expect(!CommandPaletteOverlayState.findTmuxWindow.dismissalPolicy.dismisses(.windowResignedKey))
    }

    @Test func thePaletteAndTheInboxStillCloseWhenTheirWindowStopsBeingKey() {
        #expect(CommandPaletteOverlayState.palette.dismissalPolicy.dismisses(.windowResignedKey))
        #expect(CommandPaletteOverlayState.agentInbox.dismissalPolicy.dismisses(.windowResignedKey))
    }

    @Test(arguments: [CommandPaletteOverlayState.palette, .agentInbox, .findTmuxWindow])
    func aClickOutsideOrTheMenuBarClosesEveryOverlay(state: CommandPaletteOverlayState) {
        #expect(state.dismissalPolicy.dismisses(outsideClick))
        #expect(state.dismissalPolicy.dismisses(.mainMenuBeganTracking))
    }
}
