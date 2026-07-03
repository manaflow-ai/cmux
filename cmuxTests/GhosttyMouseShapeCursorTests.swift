import AppKit
import Foundation
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for issue #5444: the terminal viewport must show the
/// text I-beam cursor over selectable text.
///
/// Root cause: cmux ignored `GHOSTTY_ACTION_MOUSE_SHAPE`, so the cursor shape
/// libghostty requests (text by default, arrow when a program enables mouse
/// reporting, pointing hand over links) never reached AppKit. The viewport kept
/// whatever cursor the parent portal had set — the arrow — at all times.
///
/// These assertions cover the previously-missing logic: the shape→`NSCursor`
/// mapping, the I-beam default before any action arrives, and the switch to the
/// arrow when a program enables mouse reporting. The live cursor rendered over a
/// window is AppKit-owned and not unit-testable.
@MainActor
@Suite
struct GhosttyMouseShapeCursorTests {
    @Test
    func textShapeMapsToIBeam() {
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_TEXT) == NSCursor.iBeam)
    }

    @Test
    func defaultShapeMapsToArrow() {
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_DEFAULT) == NSCursor.arrow)
    }

    @Test
    func pointerShapeMapsToPointingHand() {
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_POINTER) == NSCursor.pointingHand)
    }

    @Test
    func crosshairShapeMapsToCrosshair() {
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_CROSSHAIR) == NSCursor.crosshair)
    }

    @Test
    func verticalTextShapeMapsToVerticalIBeam() {
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT) == NSCursor.iBeamCursorForVerticalLayout)
    }

    @Test
    func grabShapesMapToHandCursors() {
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_GRAB) == NSCursor.openHand)
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_GRABBING) == NSCursor.closedHand)
    }

    @Test
    func disallowedShapesMapToOperationNotAllowed() {
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED) == NSCursor.operationNotAllowed)
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_NO_DROP) == NSCursor.operationNotAllowed)
    }

    @Test
    func contextMenuShapeMapsToContextualMenu() {
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU) == NSCursor.contextualMenu)
    }

    @Test
    func horizontalResizeShapesMapToLeftRightResize() {
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_COL_RESIZE) == NSCursor.resizeLeftRight)
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_E_RESIZE) == NSCursor.resizeLeftRight)
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_W_RESIZE) == NSCursor.resizeLeftRight)
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_EW_RESIZE) == NSCursor.resizeLeftRight)
    }

    @Test
    func verticalResizeShapesMapToUpDownResize() {
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_ROW_RESIZE) == NSCursor.resizeUpDown)
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_N_RESIZE) == NSCursor.resizeUpDown)
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_S_RESIZE) == NSCursor.resizeUpDown)
        #expect(GhosttyNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_NS_RESIZE) == NSCursor.resizeUpDown)
    }

    /// Before libghostty emits any mouse-shape action, the viewport must already
    /// present the text I-beam — this is the exact symptom from the issue
    /// (hovering text shows an arrow on a freshly opened pane).
    @Test
    func viewportDefaultsToIBeamBeforeAnyAction() {
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        #expect(view.effectiveTerminalCursor == NSCursor.iBeam)
    }

    /// When a program enables mouse reporting, libghostty requests the default
    /// (arrow) shape; the viewport must follow and switch back to the I-beam
    /// when text becomes selectable again.
    @Test
    func mouseReportingShapeSwitchesViewportCursor() {
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        view.applyGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_DEFAULT)
        #expect(view.effectiveTerminalCursor == NSCursor.arrow)
        view.applyGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_TEXT)
        #expect(view.effectiveTerminalCursor == NSCursor.iBeam)
    }
}
