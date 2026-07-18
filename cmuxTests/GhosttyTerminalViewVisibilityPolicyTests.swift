import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct GhosttyTerminalViewVisibilityPolicyTests {
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
