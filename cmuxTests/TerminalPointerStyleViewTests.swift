import AppKit
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal pointer style view ownership")
struct TerminalPointerStyleViewTests {
    @Test("pointer intent stays local to its terminal view")
    func pointerIntentDoesNotLeakBetweenViews() {
        let firstView = GhosttyNSView(frame: .zero)
        let secondView = GhosttyNSView(frame: .zero)

        firstView.applyTerminalPointerStyle(.focusChanged(true))
        secondView.applyTerminalPointerStyle(.focusChanged(true))
        firstView.applyTerminalPointerStyle(
            .ghosttyShape(GHOSTTY_MOUSE_SHAPE_COPY)
        )

        #expect(firstView.effectiveTerminalPointerCursor == NSCursor.dragCopy)
        #expect(secondView.effectiveTerminalPointerCursor == NSCursor.iBeam)
    }

    @Test("new native runtime resets pointer intent on the retained view")
    func runtimeRecreationResetsPointerIntentOnSameView() {
        let view = GhosttyNSView(frame: .zero)
        view.applyTerminalPointerStyle(.focusChanged(true))
        view.applyTerminalPointerStyle(
            .ghosttyShape(GHOSTTY_MOUSE_SHAPE_POINTER)
        )
        #expect(view.effectiveTerminalPointerCursor == NSCursor.pointingHand)

        view.runtimeSurfaceDidBecomeReady()

        #expect(view.effectiveTerminalPointerCursor == NSCursor.iBeam)
    }
}
