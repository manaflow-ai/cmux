import AppKit
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior of the AppKit hover reconciler behind the sidebar row close
/// affordance (#7539) and its write discipline during tracking-area
/// maintenance (#7482): reports are deduplicated against the last reported
/// value, and a report is forced only when the SwiftUI-tracked hover state
/// disagrees with pointer geometry.
@Suite struct SidebarWorkspaceRowHoverReconcilerTests {
    @Test @MainActor func hoverReconcilerRestoresCloseButtonAfterLifecycleHoverReset() {
        var state = SidebarWorkspaceRowInteractionState()

        let view = SidebarWorkspaceRowHoverReconcilerView()
        view.frame = NSRect(x: 0, y: 0, width: 120, height: 28)
        view.onPointerHoverChanged = { state.setPointerHovering($0) }

        view.reconcilePointerLocation(pointInView: NSPoint(x: 60, y: 14))
        #expect(state.shouldShowCloseButton(canCloseWorkspace: true, shortcutHintModeActive: false))

        state.setPointerHovering(false)
        #expect(!state.shouldShowCloseButton(canCloseWorkspace: true, shortcutHintModeActive: false))

        view.reconcilePointerLocation(
            pointInView: NSPoint(x: 60, y: 14),
            repairing: state.trackedPointerHovering
        )

        #expect(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "When sidebar updates or row reuse clear SwiftUI hover state while the pointer is still inside the row, the AppKit hover reconciler must restore the close affordance without waiting for another mouse move."
        )
    }

    @Test @MainActor func hoverReconcilerDoesNotRefireCallbackForUnchangedPointerState() {
        let view = SidebarWorkspaceRowHoverReconcilerView()
        view.frame = NSRect(x: 0, y: 0, width: 120, height: 28)
        var reports: [Bool] = []
        view.onPointerHoverChanged = { reports.append($0) }

        let outside = NSPoint(x: -400, y: -400)
        view.reconcilePointerLocation(pointInView: outside)
        view.reconcilePointerLocation(pointInView: outside)
        view.reconcilePointerLocation(pointInView: outside)

        #expect(
            reports.count <= 1,
            """
            \(reports.count) hover callbacks fired for three reconciles of an unchanged \
            pointer state (expected at most one initial seed). AppKit runs tracking-area \
            maintenance for every visible row on every scroll movement, so each redundant \
            callback is a SwiftUI state write per row per scroll tick at sidebar scale \
            (issue #7482).
            """
        )

        view.reconcilePointerLocation(pointInView: NSPoint(x: 60, y: 14))
        #expect(reports.last == true, "A genuine hover transition must still be reported exactly once.")
        let reportsAfterTransition = reports.count

        view.reconcilePointerLocation(pointInView: NSPoint(x: 60, y: 14))
        #expect(
            reports.count == reportsAfterTransition,
            "Re-reconciling an unchanged hovering state must not re-fire the callback."
        )
    }
}
