import AppKit
import Bonsplit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal portal host authority")
struct TerminalPortalHostAuthorityTests {
    @MainActor
    private func makeSurface() -> TerminalSurface {
        TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
    }

    @MainActor
    private func makeSnapshot(
        surface: TerminalSurface,
        pane: PaneID,
        ownershipGeneration: UInt64,
        attachGeneration: Int,
        presentation: @escaping @MainActor () -> TerminalPortalPresentation,
        onFocus: ((UUID) -> Void)? = nil,
        onTriggerFlash: (() -> Void)? = nil
    ) -> TerminalPortalMutationSnapshot {
        TerminalPortalMutationSnapshot(
            attachGeneration: attachGeneration,
            expectedSurfaceId: surface.id,
            expectedSurfaceGeneration: surface.portalBindingGeneration(),
            paneId: pane,
            ownershipGeneration: ownershipGeneration,
            portalPresentation: presentation,
            showsInactiveOverlay: false,
            showsUnreadNotificationRing: false,
            inactiveOverlayColor: .clear,
            inactiveOverlayOpacity: 0,
            searchState: nil,
            paneDropZone: nil,
            keyStateIndicatorText: nil,
            onFocus: onFocus,
            onTriggerFlash: onTriggerFlash
        )
    }

    @MainActor
    @Test
    func portalCallbacksStayValidUntilReplacementCommitsAndRejectHiddenPresentation() {
        let surface = makeSurface()
        let host = TerminalPortalHostContainerView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let pane = PaneID()
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.attachGeneration = 1
        var presentation = TerminalPortalPresentation.visible(isActive: true, zPriority: 2)
        var focusCount = 0
        var flashCount = 0
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(host), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: host.bounds, reason: "test.callback.current"
        ))
        let snapshot = makeSnapshot(
            surface: surface,
            pane: pane,
            ownershipGeneration: 1,
            attachGeneration: 1,
            presentation: { presentation },
            onFocus: { _ in focusCount += 1 },
            onTriggerFlash: { flashCount += 1 }
        )
        GhosttyTerminalView.refreshPortalHostHandlersIfOwned(
            host: host,
            hostedView: surface.hostedView,
            terminalSurface: surface,
            coordinator: coordinator,
            snapshot: snapshot
        )

        surface.hostedView.surfaceView.onFocus?()
        surface.hostedView.surfaceView.onTriggerFlash?()
        #expect(focusCount == 1)
        #expect(flashCount == 1)

        presentation = .hidden
        surface.hostedView.surfaceView.onFocus?()
        surface.hostedView.surfaceView.onTriggerFlash?()
        #expect(focusCount == 1)
        #expect(flashCount == 1)

        presentation = .visible(isActive: true, zPriority: 2)
        coordinator.attachGeneration = 2
        let previouslyCommittedFocusHandler = surface.hostedView.surfaceView.onFocus
        let previouslyCommittedFlashHandler = surface.hostedView.surfaceView.onTriggerFlash
        surface.hostedView.surfaceView.onFocus?()
        surface.hostedView.surfaceView.onTriggerFlash?()
        #expect(focusCount == 2)
        #expect(flashCount == 2)

        let replacementSnapshot = makeSnapshot(
            surface: surface,
            pane: pane,
            ownershipGeneration: 1,
            attachGeneration: 2,
            presentation: { presentation },
            onFocus: { _ in focusCount += 1 },
            onTriggerFlash: { flashCount += 1 }
        )
        GhosttyTerminalView.refreshPortalHostHandlersIfOwned(
            host: host,
            hostedView: surface.hostedView,
            terminalSurface: surface,
            coordinator: coordinator,
            snapshot: replacementSnapshot
        )

        previouslyCommittedFocusHandler?()
        previouslyCommittedFlashHandler?()
        #expect(focusCount == 2)
        #expect(flashCount == 2)
        surface.hostedView.surfaceView.onFocus?()
        surface.hostedView.surfaceView.onTriggerFlash?()
        #expect(focusCount == 3)
        #expect(flashCount == 3)
    }

    @MainActor
    @Test
    func portalCallbacksRejectOwnershipTransfer() throws {
        let surface = makeSurface()
        let oldHost = TerminalPortalHostContainerView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let newHost = NSView(frame: oldHost.bounds)
        let pane = PaneID()
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.attachGeneration = 1
        var focusCount = 0
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: oldHost.bounds, reason: "test.callback.old"
        ))
        let snapshot = makeSnapshot(
            surface: surface,
            pane: pane,
            ownershipGeneration: 1,
            attachGeneration: 1,
            presentation: { .visible(isActive: true, zPriority: 2) },
            onFocus: { _ in focusCount += 1 }
        )
        GhosttyTerminalView.installPortalHostHandlers(
            host: oldHost,
            hostedView: surface.hostedView,
            terminalSurface: surface,
            coordinator: coordinator,
            snapshot: snapshot
        )
        let staleFocusHandler = surface.hostedView.surfaceView.onFocus

        surface.updateWorkspaceId(UUID())
        coordinator.latestRequestedPortalHostOwnershipGeneration = surface.currentPortalHostOwnershipGeneration()
        staleFocusHandler?()
        #expect(focusCount == 0)
        #expect(surface.preparePortalHostReplacementIfOwned(
            hostId: ObjectIdentifier(oldHost),
            reason: "test.callback.retire"
        ) != nil)
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: newHost.bounds, reason: "test.callback.new"
        ))
        staleFocusHandler?()
        #expect(focusCount == 0)
    }

    @MainActor
    @Test
    func orphanPruneRetiresPortalLeaseAndRendererVisibility() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)
        let surface = makeSurface()
        let host = TerminalPortalHostContainerView(
            frame: CGRect(x: 20, y: 20, width: 360, height: 240)
        )
        contentView.addSubview(host)
        let portal = WindowTerminalPortal(window: window)
        let hostedId = ObjectIdentifier(surface.hostedView)
        let ownershipGeneration = surface.currentPortalHostOwnershipGeneration()
        portal.bind(hostedView: surface.hostedView, to: host, visibleInUI: true)
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(host),
            paneId: PaneID(),
            ownershipGeneration: ownershipGeneration,
            inWindow: true,
            bounds: host.bounds,
            reason: "test.orphan.owner"
        ))
        surface.hostedView.setVisibleInUI(true, refreshPolicy: .deferredToPortal)
        #expect(surface.isRendererPortalVisible)

        var entry = try #require(portal.entriesByHostedId[hostedId])
        entry.anchorView = nil
        portal.entriesByHostedId[hostedId] = entry
        portal.pruneDeadEntries()

        #expect(portal.entriesByHostedId[hostedId] == nil)
        #expect(!surface.isPortalHostOwner(hostId: ObjectIdentifier(host)))
        #expect(!surface.isRendererPortalVisible)
        #expect(!surface.hostedView.debugPortalVisibleInUI)
        #expect(surface.hostedView.isHidden)

        let replacementHost = NSView(frame: host.frame)
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(replacementHost),
            paneId: PaneID(),
            ownershipGeneration: ownershipGeneration,
            inWindow: true,
            bounds: replacementHost.bounds,
            reason: "test.orphan.replacement"
        ))
    }

    @MainActor
    @Test
    func portalTearDownRetiresStoredAnchorHostLease() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)
        let surface = makeSurface()
        let host = TerminalPortalHostContainerView(
            frame: CGRect(x: 20, y: 20, width: 360, height: 240)
        )
        contentView.addSubview(host)
        let portal = WindowTerminalPortal(window: window)
        let ownershipGeneration = surface.currentPortalHostOwnershipGeneration()
        portal.bind(hostedView: surface.hostedView, to: host, visibleInUI: true)
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(host), paneId: PaneID(),
            ownershipGeneration: ownershipGeneration, inWindow: true,
            bounds: host.bounds, reason: "test.teardown.owner"
        ))
        surface.hostedView.setVisibleInUI(true, refreshPolicy: .deferredToPortal)

        portal.tearDown()

        #expect(!surface.isPortalHostOwner(hostId: ObjectIdentifier(host)))
        #expect(!surface.isRendererPortalVisible)
        let replacementHost = NSView(frame: host.frame)
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(replacementHost), paneId: PaneID(),
            ownershipGeneration: ownershipGeneration, inWindow: true,
            bounds: replacementHost.bounds, reason: "test.teardown.replacement"
        ))
    }

    @MainActor
    @Test
    func workspaceOwnershipTransferDoesNotInvalidateBindingLifecycle() {
        let surface = makeSurface()
        let bindingGeneration = surface.portalBindingGeneration()
        let ownershipGeneration = surface.currentPortalHostOwnershipGeneration()

        surface.updateWorkspaceId(UUID())

        #expect(surface.portalBindingGeneration() == bindingGeneration)
        #expect(surface.currentPortalHostOwnershipGeneration() > ownershipGeneration)
    }

    @MainActor
    @Test
    func olderHostCannotStealLeaseAfterNewHostBinds() {
        let surface = makeSurface()
        let oldHost = NSView(), newHost = NSView()
        let oldPane = PaneID(), newPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.initial"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, ownershipGeneration: 2,
            inWindow: true, bounds: bounds, reason: "test.new.bind"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.delayed"
        ))
        #expect(
            surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(newHost))
        )
    }

    @MainActor
    @Test
    func detachedHostCannotReplaceLiveHost() {
        let surface = makeSurface()
        let oldHost = NSView(), newHost = NSView()
        let oldPane = PaneID(), newPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.initial"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, ownershipGeneration: 2,
            inWindow: false, bounds: bounds, reason: "test.new.detached"
        ))
        #expect(
            surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(oldHost))
        )
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.afterDetachedCandidate"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, ownershipGeneration: 2,
            inWindow: true, bounds: bounds, reason: "test.new.attached"
        ))
        #expect(
            surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(newHost))
        )
    }

    @MainActor
    @Test
    func sameEpochReplacementWaitsForAuthoritativeHostRetirement() {
        let surface = makeSurface()
        let oldHost = NSView(), replacementHost = NSView()
        let pane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        var retryCount = 0

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.visible.initial"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(replacementHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds,
            retryWhenAvailable: { retryCount += 1 },
            reason: "test.replacement.wait"
        ))
        #expect(retryCount == 0)
        #expect(surface.preparePortalHostReplacementIfOwned(
            hostId: ObjectIdentifier(oldHost),
            reason: "test.old.retire"
        ) != nil)
        #expect(retryCount == 1)
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(replacementHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.replacement.commit"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.stale"
        ))
    }

    @MainActor
    @Test
    func survivingSameEpochCandidateRetriesAfterLaterCandidateDismantles() {
        let surface = makeSurface()
        let oldHost = NSView(), firstCandidate = NSView(), laterCandidate = NSView()
        let pane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        var firstRetryCount = 0
        var laterRetryCount = 0

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.initial"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(firstCandidate), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds,
            retryWhenAvailable: { firstRetryCount += 1 },
            reason: "test.first.wait"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(laterCandidate), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds,
            retryWhenAvailable: { laterRetryCount += 1 },
            reason: "test.later.wait"
        ))

        surface.cancelPendingPortalHostRetry(hostId: ObjectIdentifier(laterCandidate))
        #expect(surface.preparePortalHostReplacementIfOwned(
            hostId: ObjectIdentifier(oldHost),
            reason: "test.old.retire"
        ) != nil)

        #expect(firstRetryCount == 1)
        #expect(laterRetryCount == 0)
    }

    @MainActor
    @Test
    func currentAuthorityCanRefreshWithoutCedingOwnership() {
        let surface = makeSurface()
        let host = NSView()
        let pane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(host), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.visible.initial"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(host), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.current.refresh"
        ))
        #expect(
            surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(host))
        )
    }

    @MainActor
    @Test
    func currentHostBecomingUnusableAllowsSameEpochReplacement() {
        let surface = makeSurface()
        let host = NSView(), replacementHost = NSView()
        let pane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        var retryCount = 0

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(host), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.current.visible"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(replacementHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds,
            retryWhenAvailable: {
                retryCount += 1
                #expect(surface.claimPortalHost(
                    hostId: ObjectIdentifier(replacementHost), paneId: pane, ownershipGeneration: 1,
                    inWindow: true, bounds: bounds, reason: "test.replacement.retry"
                ))
            },
            reason: "test.replacement.queued"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(host), paneId: pane, ownershipGeneration: 1,
            inWindow: false, bounds: bounds, reason: "test.current.detached"
        ))
        #expect(retryCount == 1)
        #expect(
            surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(replacementHost))
        )
    }

    @MainActor
    @Test
    func newerModelOwnershipGenerationAllowsRollbackToEarlierHost() {
        let surface = makeSurface()
        let originalHost = NSView(), movedHost = NSView()
        let originalPane = PaneID(), movedPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(originalHost), paneId: originalPane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.original.initial"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(movedHost), paneId: movedPane, ownershipGeneration: 2,
            inWindow: true, bounds: bounds, reason: "test.move.commit"
        ))
        surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(movedHost), reason: "test.move.rollback"
        )
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(originalHost), paneId: originalPane, ownershipGeneration: 3,
            inWindow: true, bounds: bounds, reason: "test.rollback.commit"
        ))
        #expect(
            surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(originalHost))
        )
    }

    @MainActor
    @Test
    func olderHostCannotReclaimAfterNewHostLeaseReleases() {
        let surface = makeSurface()
        let oldHost = NSView(), newHost = NSView()
        let oldPane = PaneID(), newPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.initial"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, ownershipGeneration: 2,
            inWindow: true, bounds: bounds, reason: "test.new.bind"
        ))
        surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(newHost), reason: "test.new.release"
        )
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.afterRelease"
        ))
    }
}
