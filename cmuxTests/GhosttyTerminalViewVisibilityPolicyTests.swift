import AppKit
import Bonsplit
import QuartzCore
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct GhosttyTerminalViewVisibilityPolicyTests {
    @Test func staleRepresentableCannotOverwriteCurrentHostAttentionColor() {
        let panel = TerminalPanel(workspaceId: UUID())
        let paneId = PaneID()
        let size = NSSize(width: 480, height: 320)
        let currentColor = WorkspaceAttentionColor(configuredHex: "#FF69B4")
        let staleColor = WorkspaceAttentionColor(configuredHex: "#33AA55")
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        window.orderFront(nil)

        let currentHost = NSHostingView(rootView: AnyView(
            GhosttyTerminalView(
                terminalSurface: panel.surface,
                paneId: paneId,
                ownershipGeneration: 1,
                isCurrentPaneOwner: { true }
            )
            .environment(\.workspaceAttentionColor, currentColor)
            .frame(width: size.width, height: size.height)
        ))
        currentHost.frame = container.bounds
        container.addSubview(currentHost)
        settleHostingView(currentHost, in: window)

        #expect(attentionStrokeHexes(in: panel.hostedView).filter { $0 == "#FF69B4" }.count >= 2)

        let staleHost = NSHostingView(rootView: AnyView(
            GhosttyTerminalView(
                terminalSurface: panel.surface,
                paneId: paneId,
                ownershipGeneration: 1,
                isCurrentPaneOwner: { false }
            )
            .environment(\.workspaceAttentionColor, staleColor)
            .frame(width: size.width, height: size.height)
        ))
        staleHost.frame = container.bounds
        container.addSubview(staleHost)
        settleHostingView(staleHost, in: window)

        let strokeHexes = attentionStrokeHexes(in: panel.hostedView)
        #expect(strokeHexes.filter { $0 == "#FF69B4" }.count >= 2)
        #expect(!strokeHexes.contains("#33AA55"))

        staleHost.rootView = AnyView(EmptyView())
        currentHost.rootView = AnyView(EmptyView())
        staleHost.removeFromSuperview()
        currentHost.removeFromSuperview()
        window.contentView = nil
        window.close()
        panel.surface.teardownSurface()
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

    private func attentionStrokeHexes(in view: NSView) -> [String] {
        shapeLayers(in: view.layer).compactMap { layer in
            guard let strokeColor = layer.strokeColor,
                  let color = NSColor(cgColor: strokeColor) else { return nil }
            return color.hexString()
        }
    }

    private func settleHostingView(_ hostingView: NSView, in window: NSWindow) {
        for _ in 0..<4 {
            window.displayIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func shapeLayers(in layer: CALayer?) -> [CAShapeLayer] {
        guard let layer else { return [] }
        return ((layer as? CAShapeLayer).map { [$0] } ?? [])
            + (layer.sublayers ?? []).flatMap { shapeLayers(in: $0) }
    }
}
