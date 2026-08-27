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

private final class PortalBindLayoutCountingView: NSView {
    private(set) var layoutCount = 0

    override func layout() {
        layoutCount += 1
        super.layout()
    }

    func resetLayoutCount() {
        layoutCount = 0
    }
}

@MainActor
@Suite(.serialized)
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

    @Test func portalReconciliationSchedulerDefersCoalescesAndPreservesRequiredWork() async {
        let scheduler = TerminalPortalReconciliationScheduler()
        var observedReasons: TerminalPortalReconciliationReasons?
        var usedLatestReconciliation = false

        scheduler.stage(reasons: [.bindingRequired]) { _ in
            Issue.record("The superseded reconciliation must not run")
        }
        scheduler.stage(reasons: [.flushPendingManualSizeReport]) { reasons in
            observedReasons = reasons
            usedLatestReconciliation = true
        }

        #expect(observedReasons == nil)
        #expect(!usedLatestReconciliation)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }

        #expect(observedReasons?.contains(.bindingRequired) == true)
        #expect(observedReasons?.contains(.flushPendingManualSizeReport) == true)
        #expect(usedLatestReconciliation)
    }

    @Test func detachedCurrentHostPersistsHiddenVisibilityBeforeRebind() async {
        let size = NSSize(width: 480, height: 320)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let host = GhosttyTerminalView.HostContainerView(frame: container.bounds)
        window.contentView = container
        container.addSubview(host)

        let panel = TerminalPanel(workspaceId: UUID())
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.attachGeneration = 1
        coordinator.hostedView = panel.hostedView
        coordinator.desiredIsVisibleInUI = true
        let snapshot = TerminalPortalReconciliationSnapshot(
            attachGeneration: coordinator.attachGeneration,
            expectedSurfaceId: panel.surface.id,
            expectedSurfaceGeneration: panel.surface.portalBindingGeneration(),
            paneId: PaneID(),
            ownershipGeneration: 1,
            isCurrentPaneOwner: { true },
            workspaceAttentionColor: WorkspaceAttentionColor(configuredHex: "#FF69B4"),
            sessionContentWidthPresentation: .disabled,
            onFocus: nil,
            onTriggerFlash: nil,
            inactiveOverlayColor: .clear,
            inactiveOverlayOpacity: 0,
            showsInactiveOverlay: false,
            searchState: nil,
            dropZone: nil
        )
        defer {
            coordinator.portalReconciliationScheduler.cancel()
            TerminalWindowPortalRegistry.detach(hostedView: panel.hostedView)
            window.close()
            panel.surface.teardownSurface()
        }

        window.orderFront(nil)
        window.displayIfNeeded()
        GhosttyTerminalView.stagePortalReconciliation(
            hostedView: panel.hostedView,
            host: host,
            coordinator: coordinator,
            terminalSurface: panel.surface,
            snapshot: snapshot,
            reasons: [.bindingRequired],
            reason: "test.initialBind"
        )
        await flushPortalReconciliationPasses()
        #expect(TerminalWindowPortalRegistry.isHostedView(panel.hostedView, boundTo: host))
        #expect(!panel.hostedView.isHidden)

        host.removeFromSuperview()
        #expect(host.window == nil)
        coordinator.desiredIsVisibleInUI = false
        GhosttyTerminalView.stagePortalReconciliation(
            hostedView: panel.hostedView,
            host: host,
            coordinator: coordinator,
            terminalSurface: panel.surface,
            snapshot: snapshot,
            reasons: [],
            reason: "test.detachedHide"
        )
        coordinator.portalReconciliationScheduler.flushPendingReconciliation()

        // Reattach before the queued geometry pass can prune the detached,
        // hidden entry. Synchronizing now distinguishes persisted visibility
        // intent from the geometry pass merely hiding or removing the view.
        container.addSubview(host)
        #expect(TerminalWindowPortalRegistry.isHostedView(panel.hostedView, boundTo: host))
        TerminalWindowPortalRegistry.synchronizeForAnchor(host, syncLayout: false)

        #expect(
            panel.hostedView.isHidden,
            "A detached current host must persist its hidden intent before the authoritative rebind"
        )
    }

    @Test func portalRegistryBindsDeferWindowLayoutUntilCoalescedPass() async {
        let size = NSSize(width: 640, height: 360)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = PortalBindLayoutCountingView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        let firstAnchor = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 360))
        let secondAnchor = NSView(frame: NSRect(x: 320, y: 0, width: 320, height: 360))
        container.addSubview(firstAnchor)
        container.addSubview(secondAnchor)

        let firstPanel = TerminalPanel(workspaceId: UUID())
        let secondPanel = TerminalPanel(workspaceId: UUID())
        defer {
            TerminalWindowPortalRegistry.detach(hostedView: firstPanel.hostedView)
            TerminalWindowPortalRegistry.detach(hostedView: secondPanel.hostedView)
            window.close()
            firstPanel.surface.teardownSurface()
            secondPanel.surface.teardownSurface()
        }

        window.orderFront(nil)
        window.displayIfNeeded()
        container.resetLayoutCount()
        container.needsLayout = true

        TerminalWindowPortalRegistry.bind(
            hostedView: firstPanel.hostedView,
            to: firstAnchor,
            visibleInUI: true,
            expectedSurfaceId: firstPanel.surface.id,
            expectedGeneration: firstPanel.surface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.bind(
            hostedView: secondPanel.hostedView,
            to: secondAnchor,
            visibleInUI: true,
            expectedSurfaceId: secondPanel.surface.id,
            expectedGeneration: secondPanel.surface.portalBindingGeneration()
        )

        #expect(
            container.layoutCount == 0,
            "Per-pane portal binds must consume committed geometry without forcing window layout"
        )

        let widthBeforeDeferredPass = firstPanel.hostedView.frame.width
        firstAnchor.setFrameSize(NSSize(width: 240, height: 360))
        #expect(
            firstPanel.hostedView.frame.width == widthBeforeDeferredPass,
            "Anchor changes must wait for the queued portal convergence pass"
        )

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        #expect(container.layoutCount > 0, "The coalesced window pass must still converge layout")
        #expect(
            firstPanel.hostedView.frame.width == 240,
            "The queued portal convergence pass must apply the latest anchor geometry"
        )
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

    private func flushPortalReconciliationPasses() async {
        await flushPortalReconciliationTurn()
        for _ in 0..<4 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
    }

    private func flushPortalReconciliationTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }
    }

    private func shapeLayers(in layer: CALayer?) -> [CAShapeLayer] {
        guard let layer else { return [] }
        return ((layer as? CAShapeLayer).map { [$0] } ?? [])
            + (layer.sublayers ?? []).flatMap { shapeLayers(in: $0) }
    }
}
