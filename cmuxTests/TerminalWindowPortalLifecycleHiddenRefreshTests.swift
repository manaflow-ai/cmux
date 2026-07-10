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
    func testStaleHostDismantleDoesNotClearNewHostCallbacks() {
        let surface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        let hostedView = surface.hostedView
        let oldHost = TerminalPortalHostContainerView(frame: .zero)
        let newHost = NSView()
        let pane = PaneID()
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.hostedView = hostedView
        var focusCount = 0
        var flashCount = 0

        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
            reason: "test.old.bind"
        ))
        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: pane, ownershipGeneration: 2,
            inWindow: true, bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
            reason: "test.new.bind"
        ))
        hostedView.setPortalHostHandlers(
            ownerHostId: ObjectIdentifier(newHost),
            focusHandler: { focusCount += 1 },
            triggerFlashHandler: { flashCount += 1 }
        )

        GhosttyTerminalView.dismantleNSView(oldHost, coordinator: coordinator)
        hostedView.surfaceView.onFocus?()
        hostedView.surfaceView.onTriggerFlash?()

        XCTAssertEqual(focusCount, 1)
        XCTAssertEqual(flashCount, 1)
    }

    @MainActor
    func testDockVisibilityRevealDefersRefreshToPortalReconcile() throws {
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

        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { store.closeAllPanels() }
        let pane = try XCTUnwrap(store.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(store.newSurface(kind: .terminal, inPane: pane, focus: true))
        let panel = try XCTUnwrap(store.panels[panelId] as? TerminalPanel)
        let portal = WindowTerminalPortal(window: window)
        portal.bind(hostedView: panel.hostedView, to: anchor, visibleInUI: false)
        drainMainQueue()
        realizeWindowLayout(window)
        XCTAssertNotNil(panel.surface.surface)
        window.makeFirstResponder(nil)
        XCTAssertFalse(window.firstResponder === panel.hostedView.surfaceView)

        panel.surface.resetDebugForceRefreshCount()
        store.setVisibleInUI(true)

        XCTAssertTrue(panel.hostedView.debugPortalActive)
        let firstResponder = window.firstResponder as? NSView
        XCTAssertTrue(
            firstResponder === panel.hostedView.surfaceView ||
                firstResponder?.isDescendant(of: panel.hostedView.surfaceView) == true,
            "Dock activation must retain terminal responder focus while deferring redraw"
        )
        XCTAssertTrue(panel.hostedView.surfaceView.desiredFocus)
        XCTAssertEqual(
            panel.surface.debugForceRefreshCount(),
            0,
            "Dock activation must leave redraw to its scheduled portal reconcile"
        )
    }

    @MainActor
    func testDockVisibilityWithTextBoxIntentDefersRefreshToPortalReconcile() throws {
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

        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { store.closeAllPanels() }
        let pane = try XCTUnwrap(store.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(store.newSurface(kind: .terminal, inPane: pane, focus: true))
        let panel = try XCTUnwrap(store.panels[panelId] as? TerminalPanel)
        let portal = WindowTerminalPortal(window: window)
        portal.bind(hostedView: panel.hostedView, to: anchor, visibleInUI: false)
        drainMainQueue()
        realizeWindowLayout(window)
        XCTAssertNotNil(panel.surface.surface)
        panel.preferTextBoxInputWhenActivated()
        XCTAssertTrue(panel.isTextBoxActive)

        panel.surface.resetDebugForceRefreshCount()
        store.setVisibleInUI(true)

        XCTAssertFalse(panel.hostedView.debugPortalActive)
        XCTAssertEqual(
            panel.surface.debugForceRefreshCount(),
            0,
            "Dock activation must leave text-box focus redraw to its scheduled portal reconcile"
        )
    }

    @MainActor
    func testWorkspacePortalProbeCostIgnoresUnrelatedWorkspacesAndPanes() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let pane = try XCTUnwrap(workspace.paneId(forPanelId: panel.id))

        TerminalPortalPresentationDebugCounters.workspaceCandidateTabProbes = 0
        let baselinePresentation = workspace.terminalPortalPresentation(panelId: panel.id, paneId: pane)
        let baselineProbeCount = TerminalPortalPresentationDebugCounters.workspaceCandidateTabProbes
        XCTAssertGreaterThan(baselineProbeCount, 0)

        XCTAssertNotNil(workspace.newTerminalSplit(
            from: panel.id,
            orientation: .horizontal,
            focus: false
        ))
        for _ in 0..<8 { _ = manager.addTab(select: false) }

        TerminalPortalPresentationDebugCounters.workspaceCandidateTabProbes = 0
        let scaledPresentation = workspace.terminalPortalPresentation(panelId: panel.id, paneId: pane)
        XCTAssertEqual(scaledPresentation, baselinePresentation)
        XCTAssertEqual(TerminalPortalPresentationDebugCounters.workspaceCandidateTabProbes, baselineProbeCount)
    }

    @MainActor
    func testDockPortalProbeCostIgnoresTabsInUnrelatedPanes() throws {
        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { store.closeAllPanels() }
        let pane = try XCTUnwrap(store.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(store.newSurface(kind: .terminal, inPane: pane, focus: true))
        store.setVisibleInUI(true)

        TerminalPortalPresentationDebugCounters.dockCandidateTabProbes = 0
        let baselinePresentation = store.terminalPortalPresentation(panelId: panelId, paneId: pane)
        let baselineProbeCount = TerminalPortalPresentationDebugCounters.dockCandidateTabProbes
        XCTAssertGreaterThan(baselineProbeCount, 0)

        let splitPanelId = try XCTUnwrap(store.newSplit(
            kind: .terminal,
            orientation: .horizontal,
            insertFirst: false,
            sourcePanelId: panelId,
            focus: false
        ))
        let unrelatedPane = try XCTUnwrap(store.paneId(forPanelId: splitPanelId))
        for _ in 0..<8 {
            _ = store.newSurface(kind: .terminal, inPane: unrelatedPane, focus: false)
        }

        TerminalPortalPresentationDebugCounters.dockCandidateTabProbes = 0
        let scaledPresentation = store.terminalPortalPresentation(panelId: panelId, paneId: pane)
        XCTAssertEqual(scaledPresentation, baselinePresentation)
        XCTAssertEqual(TerminalPortalPresentationDebugCounters.dockCandidateTabProbes, baselineProbeCount)
    }

    @MainActor
    func testTransientReattachDistinguishesAnnouncedAndOrphanedNilAnchors() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView)
        let surface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        let orphanedAnchor = NSView(frame: NSRect(x: 20, y: 20, width: 360, height: 240))
        contentView.addSubview(orphanedAnchor)
        let portal = WindowTerminalPortal(window: window)
        let hostedId = ObjectIdentifier(surface.hostedView)
        portal.bind(hostedView: surface.hostedView, to: orphanedAnchor, visibleInUI: true)
        var entry = try XCTUnwrap(portal.entriesByHostedId[hostedId])
        entry.anchorView = nil
        portal.entriesByHostedId[hostedId] = entry
        portal.pruneDeadEntries()
        XCTAssertEqual(portal.debugEntryCount(), 0)

        let transientAnchor = NSView(frame: NSRect(x: 20, y: 20, width: 360, height: 240))
        contentView.addSubview(transientAnchor)
        portal.bind(hostedView: surface.hostedView, to: transientAnchor, visibleInUI: true)
        portal.prepareEntryForTransientReattach(forHostedId: hostedId)
        entry = try XCTUnwrap(portal.entriesByHostedId[hostedId])
        entry.anchorView = nil
        portal.entriesByHostedId[hostedId] = entry
        portal.pruneDeadEntries()
        XCTAssertEqual(portal.debugEntryCount(), 1)
    }

    @MainActor
    func testDeferredPortalBindRefreshesAfterRepresentableTurn() throws {
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

        let portal = WindowTerminalPortal(window: window)
        let surface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: false)
        drainMainQueue()
        realizeWindowLayout(window)

        surface.resetDebugForceRefreshCount()
        portal.bind(
            hostedView: surface.hostedView,
            to: anchor,
            visibleInUI: true,
            deferLayoutSynchronization: true
        )
        portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)

        XCTAssertEqual(
            surface.debugForceRefreshCount(),
            0,
            "A representable-owned bind must not force display while its view update is active"
        )

        drainMainQueue()
        XCTAssertEqual(
            surface.debugForceRefreshCount(),
            1,
            "The portal owner should refresh once after binding and geometry settle"
        )
    }

    @MainActor
    func testPortalSkipsSynchronousRefreshForHiddenSurfaces() throws {
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
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let portal = WindowTerminalPortal(window: window)
        let visibleAnchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        let hiddenAnchor = NSView(frame: NSRect(x: 260, y: 8, width: 240, height: 160))
        contentView.addSubview(visibleAnchor)
        contentView.addSubview(hiddenAnchor)

        let visibleSurface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        let hiddenSurface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        portal.bind(hostedView: visibleSurface.hostedView, to: visibleAnchor, visibleInUI: true)
        portal.bind(hostedView: hiddenSurface.hostedView, to: hiddenAnchor, visibleInUI: false)
        portal.synchronizeHostedViewForAnchor(visibleAnchor)
        drainMainQueue()
        realizeWindowLayout(window)

        visibleSurface.resetDebugForceRefreshCount()
        hiddenSurface.resetDebugForceRefreshCount()

        // Move BOTH anchors: both hosted views get geometry bookkeeping, but
        // only the visible one may pay for the synchronous redraw — one
        // layout pass syncs every hosted view in the window, and a mirror
        // workspace parks 20+ surfaces on unselected tabs.
        visibleAnchor.setFrameSize(NSSize(width: 220, height: 150))
        hiddenAnchor.setFrameSize(NSSize(width: 220, height: 150))
        portal.synchronizeHostedViewForAnchor(visibleAnchor)
        drainMainQueue()

        XCTAssertEqual(
            hiddenSurface.debugForceRefreshCount(),
            0,
            "A hidden (unselected-tab) surface must not receive the synchronous GPU-blocking refresh on geometry sync"
        )
        withExtendedLifetime((visibleSurface, hiddenSurface)) {}
    }
}
