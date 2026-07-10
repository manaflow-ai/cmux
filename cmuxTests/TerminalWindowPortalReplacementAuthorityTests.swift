@preconcurrency import XCTest
import AppKit
import Bonsplit
import CmuxTerminal
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalWindowPortalLifecycleTests {
    @MainActor
    func testCancelledTransientReattachPrunesVisiblePortalEntry() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        let contentView = try XCTUnwrap(window.contentView)
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 360, height: 240))
        contentView.addSubview(anchor)
        let surface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        let hostedId = ObjectIdentifier(surface.hostedView)
        TerminalWindowPortalRegistry.bind(
            hostedView: surface.hostedView,
            to: anchor,
            visibleInUI: true
        )
        let portal = try XCTUnwrap(TerminalWindowPortalRegistry.mappedPortal(for: surface.hostedView))

        let ownerHost = NSView(), candidateHost = NSView()
        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(ownerHost), paneId: PaneID(), ownershipGeneration: 11,
            inWindow: true, bounds: CGRect(x: 0, y: 0, width: 360, height: 240),
            reason: "test.cancelled.owner"
        ))
        let recoveryGeneration = try XCTUnwrap(surface.preparePortalHostReplacementIfOwned(
            hostId: ObjectIdentifier(ownerHost),
            reason: "test.cancelled.prepare"
        ))
        portal.updateTransientReattachCandidate(
            forHostedId: hostedId,
            hostId: ObjectIdentifier(candidateHost),
            ownershipGeneration: recoveryGeneration,
            isUsable: true
        )
        portal.prepareEntryForTransientReattach(
            forHostedId: hostedId,
            ownershipGeneration: recoveryGeneration
        )
        var entry = try XCTUnwrap(portal.entriesByHostedId[hostedId])
        entry.anchorView = nil
        portal.entriesByHostedId[hostedId] = entry
        portal.pruneDeadEntries()
        XCTAssertEqual(portal.debugEntryCount(), 1)

        portal.unregisterTransientReattachCandidate(
            forHostedId: hostedId,
            hostId: ObjectIdentifier(candidateHost)
        )

        XCTAssertEqual(portal.debugEntryCount(), 0)
        XCTAssertTrue(surface.hostedView.isHidden)
        XCTAssertNil(surface.hostedView.superview)
    }

    @MainActor
    func testUsableTransientCandidateThatNeverBindsIsPruned() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)
        let contentView = try XCTUnwrap(window.contentView)
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 360, height: 240))
        contentView.addSubview(anchor)
        let surface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        let hostedId = ObjectIdentifier(surface.hostedView)
        TerminalWindowPortalRegistry.bind(
            hostedView: surface.hostedView,
            to: anchor,
            visibleInUI: true
        )
        let portal = try XCTUnwrap(TerminalWindowPortalRegistry.mappedPortal(for: surface.hostedView))

        let ownerHost = NSView()
        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(ownerHost), paneId: PaneID(), ownershipGeneration: 13,
            inWindow: true, bounds: CGRect(x: 0, y: 0, width: 360, height: 240),
            reason: "test.neverBind.owner"
        ))
        let recoveryGeneration = try XCTUnwrap(surface.preparePortalHostReplacementIfOwned(
            hostId: ObjectIdentifier(ownerHost),
            reason: "test.neverBind.prepare"
        ))
        portal.prepareEntryForTransientReattach(
            forHostedId: hostedId,
            ownershipGeneration: recoveryGeneration
        )
        var entry = try XCTUnwrap(portal.entriesByHostedId[hostedId])
        entry.anchorView = nil
        portal.entriesByHostedId[hostedId] = entry

        let candidateHost = TerminalPortalHostContainerView(
            frame: CGRect(x: 0, y: 0, width: 360, height: 240)
        )
        contentView.addSubview(candidateHost)
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.attachGeneration = 1
        let snapshot = TerminalPortalMutationSnapshot(
            attachGeneration: 1,
            expectedSurfaceId: surface.id,
            expectedSurfaceGeneration: surface.portalBindingGeneration(),
            paneId: PaneID(),
            ownershipGeneration: recoveryGeneration,
            portalPresentation: { .visible(isActive: true, zPriority: 2) },
            showsInactiveOverlay: false,
            showsUnreadNotificationRing: false,
            inactiveOverlayColor: .clear,
            inactiveOverlayOpacity: 0,
            searchState: nil,
            paneDropZone: nil,
            keyStateIndicatorText: nil,
            onFocus: nil,
            onTriggerFlash: nil
        )
        let drain = try XCTUnwrap(GhosttyTerminalView.schedulePortalMutation(
            host: candidateHost,
            hostedView: surface.hostedView,
            terminalSurface: surface,
            coordinator: coordinator,
            snapshot: snapshot,
            reason: "test.neverBind.candidate"
        ))
        XCTAssertEqual(
            portal.transientReattachCandidatesByHostedId[hostedId]?[ObjectIdentifier(candidateHost)]?.ownershipGeneration,
            recoveryGeneration,
            "The production scheduler path must register the live replacement candidate"
        )
        portal.pruneDeadEntries()
        XCTAssertEqual(portal.debugEntryCount(), 1)

        coordinator.attachGeneration = 2
        await drain.value

        XCTAssertEqual(portal.debugEntryCount(), 0)
        XCTAssertTrue(surface.hostedView.isHidden)
        XCTAssertNil(surface.hostedView.superview)
    }

    @MainActor
    func testTransientTinyCandidateWaitsForMutationDrainBeforePruning() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)
        let contentView = try XCTUnwrap(window.contentView)
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 360, height: 240))
        contentView.addSubview(anchor)
        let surface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        let hostedId = ObjectIdentifier(surface.hostedView)
        TerminalWindowPortalRegistry.bind(
            hostedView: surface.hostedView,
            to: anchor,
            visibleInUI: true
        )
        let portal = try XCTUnwrap(TerminalWindowPortalRegistry.mappedPortal(for: surface.hostedView))

        let ownerHost = NSView()
        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(ownerHost), paneId: PaneID(), ownershipGeneration: 15,
            inWindow: true, bounds: anchor.bounds, reason: "test.tiny.owner"
        ))
        let recoveryGeneration = try XCTUnwrap(surface.preparePortalHostReplacementIfOwned(
            hostId: ObjectIdentifier(ownerHost),
            reason: "test.tiny.prepare"
        ))
        portal.prepareEntryForTransientReattach(
            forHostedId: hostedId,
            ownershipGeneration: recoveryGeneration
        )
        var entry = try XCTUnwrap(portal.entriesByHostedId[hostedId])
        entry.anchorView = nil
        portal.entriesByHostedId[hostedId] = entry

        let candidateHost = TerminalPortalHostContainerView(frame: anchor.bounds)
        contentView.addSubview(candidateHost)
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.attachGeneration = 1
        let snapshot = TerminalPortalMutationSnapshot(
            attachGeneration: 1,
            expectedSurfaceId: surface.id,
            expectedSurfaceGeneration: surface.portalBindingGeneration(),
            paneId: PaneID(),
            ownershipGeneration: recoveryGeneration,
            portalPresentation: { .visible(isActive: true, zPriority: 2) },
            showsInactiveOverlay: false,
            showsUnreadNotificationRing: false,
            inactiveOverlayColor: .clear,
            inactiveOverlayOpacity: 0,
            searchState: nil,
            paneDropZone: nil,
            keyStateIndicatorText: nil,
            onFocus: nil,
            onTriggerFlash: nil
        )
        let drain = try XCTUnwrap(GhosttyTerminalView.schedulePortalMutation(
            host: candidateHost,
            hostedView: surface.hostedView,
            terminalSurface: surface,
            coordinator: coordinator,
            snapshot: snapshot,
            reason: "test.tiny.usable"
        ))
        XCTAssertEqual(
            portal.transientReattachCandidatesByHostedId[hostedId]?[ObjectIdentifier(candidateHost)]?.ownershipGeneration,
            recoveryGeneration
        )

        candidateHost.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        _ = GhosttyTerminalView.schedulePortalMutation(
            host: candidateHost,
            hostedView: surface.hostedView,
            terminalSurface: surface,
            coordinator: coordinator,
            snapshot: snapshot,
            reason: "test.tiny.placeholder"
        )
        XCTAssertEqual(
            portal.transientReattachCandidatesByHostedId[hostedId]?[ObjectIdentifier(candidateHost)]?.isUsable,
            false
        )
        portal.pruneDeadEntries()
        XCTAssertEqual(portal.debugEntryCount(), 1, "Tiny intermediate geometry must survive until the shared drain")

        coordinator.attachGeneration = 2
        await drain.value
        await Task.yield()

        XCTAssertEqual(portal.debugEntryCount(), 0)
        XCTAssertTrue(surface.hostedView.isHidden)
    }

    @MainActor
    func testOlderCandidateCleanupPreservesNewerRecoveryGeneration() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView)
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 360, height: 240))
        contentView.addSubview(anchor)
        let surface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        let portal = WindowTerminalPortal(window: window)
        let hostedId = ObjectIdentifier(surface.hostedView)
        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)

        let oldOwner = NSView(), newOwner = NSView(), candidate = NSView()
        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldOwner), paneId: PaneID(), ownershipGeneration: 18,
            inWindow: true, bounds: anchor.bounds, reason: "test.generation.oldOwner"
        ))
        let oldGeneration = try XCTUnwrap(surface.preparePortalHostReplacementIfOwned(
            hostId: ObjectIdentifier(oldOwner), reason: "test.generation.oldPrepare"
        ))
        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(newOwner), paneId: PaneID(), ownershipGeneration: 19,
            inWindow: true, bounds: anchor.bounds, reason: "test.generation.newOwner"
        ))
        let newGeneration = try XCTUnwrap(surface.preparePortalHostReplacementIfOwned(
            hostId: ObjectIdentifier(newOwner), reason: "test.generation.newPrepare"
        ))
        portal.prepareEntryForTransientReattach(
            forHostedId: hostedId,
            ownershipGeneration: newGeneration
        )
        portal.updateTransientReattachCandidate(
            forHostedId: hostedId,
            hostId: ObjectIdentifier(candidate),
            ownershipGeneration: newGeneration,
            isUsable: true
        )

        portal.unregisterTransientReattachCandidate(
            forHostedId: hostedId,
            hostId: ObjectIdentifier(candidate),
            ownershipGeneration: oldGeneration
        )
        portal.pruneDeadEntries()

        XCTAssertEqual(
            portal.transientReattachCandidatesByHostedId[hostedId]?[ObjectIdentifier(candidate)]?.ownershipGeneration,
            newGeneration
        )
        XCTAssertEqual(portal.entriesByHostedId[hostedId]?.transientAnchorRecoveryGeneration, newGeneration)
        XCTAssertEqual(portal.debugEntryCount(), 1)
    }

    @MainActor
    func testAuthoritativeHostGeometryUpdateDoesNotRegisterReplacementCandidate() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)
        let contentView = try XCTUnwrap(window.contentView)
        let host = TerminalPortalHostContainerView(
            frame: CGRect(x: 20, y: 20, width: 360, height: 240)
        )
        contentView.addSubview(host)
        let surface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        TerminalWindowPortalRegistry.bind(
            hostedView: surface.hostedView,
            to: host,
            visibleInUI: true
        )
        let portal = try XCTUnwrap(TerminalWindowPortalRegistry.mappedPortal(for: surface.hostedView))
        let pane = PaneID()
        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(host), paneId: pane, ownershipGeneration: 17,
            inWindow: true, bounds: host.bounds, reason: "test.current.geometry.owner"
        ))
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.attachGeneration = 1
        let snapshot = TerminalPortalMutationSnapshot(
            attachGeneration: 1,
            expectedSurfaceId: surface.id,
            expectedSurfaceGeneration: surface.portalBindingGeneration(),
            paneId: pane,
            ownershipGeneration: 17,
            portalPresentation: { .visible(isActive: true, zPriority: 2) },
            showsInactiveOverlay: false,
            showsUnreadNotificationRing: false,
            inactiveOverlayColor: .clear,
            inactiveOverlayOpacity: 0,
            searchState: nil,
            paneDropZone: nil,
            keyStateIndicatorText: nil,
            onFocus: nil,
            onTriggerFlash: nil
        )
        let drain = try XCTUnwrap(GhosttyTerminalView.schedulePortalMutation(
            host: host,
            hostedView: surface.hostedView,
            terminalSurface: surface,
            coordinator: coordinator,
            snapshot: snapshot,
            reason: "test.current.geometry"
        ))

        XCTAssertNil(portal.transientReattachCandidatesByHostedId[ObjectIdentifier(surface.hostedView)])
        await drain.value
        XCTAssertNil(portal.transientReattachCandidatesByHostedId[ObjectIdentifier(surface.hostedView)])
    }

    @MainActor
    func testOlderCleanupTokenPreservesNewerSameGenerationCandidate() {
        let window = NSWindow(
            contentRect: .zero, styleMask: [], backing: .buffered, defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowTerminalPortal(window: window)
        let hostedView = NSView(), candidateView = NSView()
        let hostedId = ObjectIdentifier(hostedView)
        let candidateId = ObjectIdentifier(candidateView)

        portal.updateTransientReattachCandidate(
            forHostedId: hostedId, hostId: candidateId,
            ownershipGeneration: 23, registrationToken: 1, isUsable: true
        )
        portal.updateTransientReattachCandidate(
            forHostedId: hostedId, hostId: candidateId,
            ownershipGeneration: 23, registrationToken: 2, isUsable: true
        )
        portal.unregisterTransientReattachCandidate(
            forHostedId: hostedId, hostId: candidateId,
            ownershipGeneration: 23, registrationToken: 1
        )

        XCTAssertEqual(
            portal.transientReattachCandidatesByHostedId[hostedId]?[candidateId]?.registrationToken,
            2,
            "Cleanup from an older drain must not remove a newer registration"
        )
        withExtendedLifetime((hostedView, candidateView)) {}
    }

    @MainActor
    func testBulkSynchronizationPreparesOnceIndependentOfEntryCount() {
        for entryCount in [0, 1, 100] {
            var preparationCount = 0
            var synchronizedEntries: [Int] = []

            TerminalPortalBulkSynchronization.run(
                prepare: { preparationCount += 1 },
                entries: { Array(0..<entryCount) },
                synchronize: { synchronizedEntries.append($0) }
            )

            XCTAssertEqual(preparationCount, 1)
            XCTAssertEqual(synchronizedEntries, Array(0..<entryCount))
        }
    }
}
