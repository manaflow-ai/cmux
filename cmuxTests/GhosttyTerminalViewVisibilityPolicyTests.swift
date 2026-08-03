import AppKit
import CmuxSettings
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct GhosttyTerminalViewVisibilityPolicyTests {
    /// SwiftUI calls `updateNSView` while its graph transaction is open. The
    /// attach step may update ownership and surface lifecycle state there, but
    /// geometry must wait for the normal AppKit layout pass. A synchronous
    /// descendant layout flush from attach can spend tens of seconds walking
    /// the whole window when another scene changes its workspace collection.
    @Test func surfaceAttachDefersGeometryToTheAppKitLayoutPass() {
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        hostedView.needsLayout = true
        hostedView.layoutSubtreeIfNeeded()

        let staleSurfaceSize = NSSize(width: 13, height: 17)
        hostedView.surfaceView.setFrameSize(staleSurfaceSize)
        hostedView.attachSurface(surface)

        #expect(
            hostedView.surfaceView.frame.size == staleSurfaceSize,
            "Representable attachment must not synchronously flush terminal geometry"
        )

        hostedView.layoutSubtreeIfNeeded()
        #expect(
            hostedView.surfaceView.frame.size != staleSurfaceSize,
            "The next AppKit layout pass must still reconcile terminal geometry"
        )

        let staleWidthUpdateSize = NSSize(width: 19, height: 23)
        hostedView.surfaceView.setFrameSize(staleWidthUpdateSize)
        hostedView.setSessionContentWidthPresentation(SessionContentWidthPresentation(
            storedMaximumWidth: 180,
            storedAlignment: SessionContentAlignment.center.rawValue
        ))

        #expect(
            hostedView.surfaceView.frame.size == staleWidthUpdateSize,
            "Representable presentation updates must not synchronously flush terminal geometry"
        )

        hostedView.layoutSubtreeIfNeeded()
        #expect(
            hostedView.surfaceView.frame.size != staleWidthUpdateSize,
            "The next AppKit layout pass must apply the new content-width presentation"
        )
    }

    @Test func immediateStateUpdateAllowedWhenDesiredStateIsHidden() {
        #expect(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: false,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    @Test func immediateStateUpdateAllowedWhenBoundToCurrentHost() {
        #expect(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            )
        )
    }

    @Test func immediateStateUpdateSkippedForStaleHostBoundElsewhere() {
        #expect(
            !GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    @Test func immediateStateUpdateAllowedWhenUnboundAndNotAttachedAnywhere() {
        #expect(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: false,
                isBoundToCurrentHost: false
            )
        )
    }

    // The full action: ownership and binding liveness gate SHOWING, but a
    // host the hosted view is currently bound to may always HIDE it — and
    // only hide it; active/focus state stays ownership-gated. The regression
    // this pins: a deselected tab's bound-but-disowned host had its
    // visible=false deferred forever, leaving the hidden tab's surface drawn
    // over the selected tab's panes.
    @Test func boundHostMayHideWithoutOwningTheLease() {
        #expect(
            GhosttyTerminalView.immediateHostedStateAction(
                hostOwnsPortal: false,
                portalBindingLive: true,
                desiredVisibleInUI: false,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            ) == .hideOnly
        )
    }

    @Test func boundHostMayHideEvenWhenBindingGenerationMoved() {
        #expect(
            GhosttyTerminalView.immediateHostedStateAction(
                hostOwnsPortal: false,
                portalBindingLive: false,
                desiredVisibleInUI: false,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            ) == .hideOnly
        )
    }

    @Test func unboundHostMayNotHideAnotherHostsContent() {
        #expect(
            GhosttyTerminalView.immediateHostedStateAction(
                hostOwnsPortal: false,
                portalBindingLive: true,
                desiredVisibleInUI: false,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            ) == .deferred
        )
    }

    @Test func showingStillRequiresOwnership() {
        #expect(
            GhosttyTerminalView.immediateHostedStateAction(
                hostOwnsPortal: false,
                portalBindingLive: true,
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            ) == .deferred
        )
    }

    @Test func showingStillRequiresLiveBinding() {
        #expect(
            GhosttyTerminalView.immediateHostedStateAction(
                hostOwnsPortal: true,
                portalBindingLive: false,
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            ) == .deferred
        )
    }

    @Test func owningHiderAppliesBothFlagsNotJustTheHide() {
        #expect(
            GhosttyTerminalView.immediateHostedStateAction(
                hostOwnsPortal: true,
                portalBindingLive: true,
                desiredVisibleInUI: false,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            ) == .applyVisibleAndActive
        )
    }

    @Test func ownerWithLiveBindingShowsBoundContent() {
        #expect(
            GhosttyTerminalView.immediateHostedStateAction(
                hostOwnsPortal: true,
                portalBindingLive: true,
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            ) == .applyVisibleAndActive
        )
    }

    @Test func hostGeometryCallbackUsesImmediateSyncWithoutLayoutFlush() {
        switch GhosttyTerminalView.hostCallbackPortalGeometrySynchronizationAction(window: 3873) {
        case .synchronizeWithoutLayoutFlush(let window):
            #expect(window == 3873)
        case .skip:
            Issue.record("Window-attached host callbacks should immediately reconcile portal geometry without layout flushes")
        }
    }

    @Test func hostGeometryCallbackSkipsWithoutWindow() {
        switch GhosttyTerminalView.hostCallbackPortalGeometrySynchronizationAction(window: Optional<Int>.none) {
        case .synchronizeWithoutLayoutFlush:
            Issue.record("Detached host callbacks must not synchronize terminal portal geometry")
        case .skip:
            break
        }
    }
}
