import AppKit
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SidebarWorkspaceRowHoverReconcilerTests {
    @Test @MainActor func restoresCloseButtonAfterLifecycleHoverReset() async {
        var state = SidebarWorkspaceRowInteractionState()

        let view = SidebarWorkspaceRowHoverReconcilerView()
        view.frame = NSRect(x: 0, y: 0, width: 120, height: 28)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            view.onPointerHoverChanged = {
                state.setPointerHovering($0)
                continuation.resume()
            }
            view.reconcilePointerLocation(pointInView: NSPoint(x: 60, y: 14))
        }
        #expect(state.shouldShowCloseButton(canCloseWorkspace: true, shortcutHintModeActive: false))

        state.setPointerHovering(false)
        #expect(!state.shouldShowCloseButton(canCloseWorkspace: true, shortcutHintModeActive: false))

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            view.onPointerHoverChanged = {
                state.setPointerHovering($0)
                continuation.resume()
            }
            view.reconcilePointerLocation(pointInView: NSPoint(x: 60, y: 14))
        }

        #expect(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "When sidebar updates or row reuse clear SwiftUI hover state while the pointer is still inside the row, the AppKit hover reconciler must restore the close affordance without waiting for another mouse move."
        )
    }

    @Test @MainActor func doesNotMutateSwiftUIOnTheAppKitLifecycleStack() async {
        var reportedHover: Bool?
        let view = SidebarWorkspaceRowHoverReconcilerView()
        view.frame = NSRect(x: 0, y: 0, width: 120, height: 28)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            view.onPointerHoverChanged = {
                reportedHover = $0
                continuation.resume()
            }

            view.reconcilePointerLocation(pointInView: NSPoint(x: 60, y: 14))

            #expect(
                reportedHover == nil,
                """
                AppKit hover reconciliation must not call into SwiftUI synchronously. The real row invokes this path \
                from updateTrackingAreas and viewDidMoveToWindow; a synchronous Binding write there re-enters \
                NSHostingView layout and can livelock AttributeGraph.
                """
            )
        }
        #expect(reportedHover == true)
    }

    @Test @MainActor func dismantlingDropsBufferedHoverEvents() async {
        var reportedHover: Bool?
        let view = SidebarWorkspaceRowHoverReconcilerView()
        view.frame = NSRect(x: 0, y: 0, width: 120, height: 28)
        view.onPointerHoverChanged = { reportedHover = $0 }

        view.reconcilePointerLocation(pointInView: NSPoint(x: 60, y: 14))
        SidebarWorkspaceRowHoverReconciler.dismantleNSView(view, coordinator: ())
        await Task.yield()

        #expect(
            reportedHover == nil,
            "Dismantling the representable must discard buffered hover events before row teardown state can be overwritten."
        )
    }
}
