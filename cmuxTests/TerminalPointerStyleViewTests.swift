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
        let firstRuntimeLifetimeId = UUID()
        let secondRuntimeLifetimeId = UUID()

        firstView.prepareForRuntimeSurfaceCreation(
            runtimeLifetimeId: firstRuntimeLifetimeId
        )
        secondView.prepareForRuntimeSurfaceCreation(
            runtimeLifetimeId: secondRuntimeLifetimeId
        )
        firstView.applyTerminalPointerStyle(.focusChanged(true))
        secondView.applyTerminalPointerStyle(.focusChanged(true))
        firstView.applyTerminalPointerStyle(
            .ghosttyShape(
                GHOSTTY_MOUSE_SHAPE_COPY,
                runtimeLifetimeId: firstRuntimeLifetimeId
            )
        )

        #expect(firstView.effectiveTerminalPointerCursor == NSCursor.dragCopy)
        #expect(secondView.effectiveTerminalPointerCursor == NSCursor.iBeam)
    }

    @Test("native runtime lifecycle gates pointer intent on the retained view")
    func runtimeLifecycleGatesPointerIntentOnSameView() {
        let view = GhosttyNSView(frame: .zero)
        let oldRuntimeLifetimeId = UUID()
        view.prepareForRuntimeSurfaceCreation(
            runtimeLifetimeId: oldRuntimeLifetimeId
        )
        view.applyTerminalPointerStyle(.focusChanged(true))
        view.applyTerminalPointerStyle(
            .ghosttyShape(
                GHOSTTY_MOUSE_SHAPE_POINTER,
                runtimeLifetimeId: oldRuntimeLifetimeId
            )
        )
        #expect(view.effectiveTerminalPointerCursor == NSCursor.pointingHand)

        view.runtimeSurfaceDidEnd(runtimeLifetimeId: oldRuntimeLifetimeId)
        view.applyTerminalPointerStyle(
            .ghosttyShape(
                GHOSTTY_MOUSE_SHAPE_POINTER,
                runtimeLifetimeId: oldRuntimeLifetimeId
            )
        )
        #expect(view.effectiveTerminalPointerCursor == NSCursor.iBeam)

        let newRuntimeLifetimeId = UUID()
        view.prepareForRuntimeSurfaceCreation(
            runtimeLifetimeId: newRuntimeLifetimeId
        )
        view.applyTerminalPointerStyle(
            .ghosttyShape(
                GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
                runtimeLifetimeId: newRuntimeLifetimeId
            )
        )
        view.runtimeSurfaceDidEnd(runtimeLifetimeId: oldRuntimeLifetimeId)
        view.runtimeSurfaceDidBecomeReady()

        #expect(view.effectiveTerminalPointerCursor == NSCursor.crosshair)
    }

    @Test("stale runtime teardown preserves replacement pointer state")
    func staleRuntimeTeardownPreservesReplacementPointerState() {
        let view = GhosttyNSView(frame: .zero)
        let oldRuntimeLifetimeId = UUID()
        view.prepareForRuntimeSurfaceCreation(
            runtimeLifetimeId: oldRuntimeLifetimeId
        )
        view.applyTerminalPointerStyle(.focusChanged(true))
        view.applyTerminalPointerStyle(
            .ghosttyShape(
                GHOSTTY_MOUSE_SHAPE_POINTER,
                runtimeLifetimeId: oldRuntimeLifetimeId
            )
        )

        let replacementRuntimeLifetimeId = UUID()
        view.prepareForRuntimeSurfaceCreation(
            runtimeLifetimeId: replacementRuntimeLifetimeId
        )
        view.applyTerminalPointerStyle(
            .ghosttyShape(
                GHOSTTY_MOUSE_SHAPE_POINTER,
                runtimeLifetimeId: replacementRuntimeLifetimeId
            )
        )
        view.applyTerminalPointerStyle(
            .ghosttyLinkHoverChanged(
                true,
                runtimeLifetimeId: replacementRuntimeLifetimeId
            )
        )
        view.applyTerminalPointerStyle(.focusChanged(false))

        view.runtimeSurfaceDidEnd(runtimeLifetimeId: oldRuntimeLifetimeId)
        view.applyTerminalPointerStyle(.focusChanged(true))

        #expect(view.effectiveTerminalPointerCursor == NSCursor.pointingHand)

        let didInvalidateCursorRects = view.applyTerminalPointerStyle(
            .ghosttyShape(
                GHOSTTY_MOUSE_SHAPE_POINTER,
                runtimeLifetimeId: replacementRuntimeLifetimeId
            )
        )
        #expect(didInvalidateCursorRects)
        #expect(view.effectiveTerminalPointerCursor == NSCursor.pointingHand)
    }

    @Test("focus regain restores the cached base while awaiting fresh shape")
    func focusRegainRestoresStationaryLinkBasePointer() {
        let view = GhosttyNSView(frame: .zero)
        let runtimeLifetimeId = UUID()
        view.prepareForRuntimeSurfaceCreation(
            runtimeLifetimeId: runtimeLifetimeId
        )
        view.applyTerminalPointerStyle(.focusChanged(true))
        view.applyTerminalPointerStyle(
            .ghosttyShape(
                GHOSTTY_MOUSE_SHAPE_POINTER,
                runtimeLifetimeId: runtimeLifetimeId
            )
        )
        view.applyTerminalPointerStyle(
            .ghosttyLinkHoverChanged(
                true,
                runtimeLifetimeId: runtimeLifetimeId
            )
        )
        view.applyTerminalPointerStyle(.focusChanged(false))
        #expect(view.effectiveTerminalPointerCursor == NSCursor.iBeam)

        let didInvalidateCursorRects = view.applyTerminalPointerStyle(
            .focusChanged(true)
        )

        #expect(didInvalidateCursorRects)
        #expect(view.effectiveTerminalPointerCursor == NSCursor.pointingHand)

        view.applyTerminalPointerStyle(
            .ghosttyShape(
                GHOSTTY_MOUSE_SHAPE_POINTER,
                runtimeLifetimeId: runtimeLifetimeId
            )
        )
        #expect(view.effectiveTerminalPointerCursor == NSCursor.pointingHand)
    }

    @Test("persistent pointer shapes survive a focus epoch change")
    func persistentPointerShapeSurvivesFocusEpochChange() {
        let view = GhosttyNSView(frame: .zero)
        let runtimeLifetimeId = UUID()
        view.prepareForRuntimeSurfaceCreation(
            runtimeLifetimeId: runtimeLifetimeId
        )
        view.applyTerminalPointerStyle(.focusChanged(true))
        view.applyTerminalPointerStyle(
            .ghosttyShape(
                GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
                runtimeLifetimeId: runtimeLifetimeId
            )
        )
        view.applyTerminalPointerStyle(.focusChanged(false))
        view.applyTerminalPointerStyle(.focusChanged(true))

        let didApplyDelayedShape = view.applyTerminalPointerStyle(
            .ghosttyShape(
                GHOSTTY_MOUSE_SHAPE_COPY,
                runtimeLifetimeId: runtimeLifetimeId
            ),
            focusGeneration: 1
        )

        #expect(!didApplyDelayedShape)
        #expect(view.effectiveTerminalPointerCursor == NSCursor.crosshair)

        let didApplyFreshShape = view.applyTerminalPointerStyle(
            .ghosttyShape(
                GHOSTTY_MOUSE_SHAPE_COPY,
                runtimeLifetimeId: runtimeLifetimeId
            ),
            focusGeneration: 3
        )

        #expect(didApplyFreshShape)
        #expect(view.effectiveTerminalPointerCursor == NSCursor.dragCopy)
    }
}
