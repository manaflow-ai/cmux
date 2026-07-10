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
        TerminalWindowPortalRegistry.bind(
            hostedView: panel.hostedView,
            to: anchor,
            visibleInUI: false,
            expectedSurfaceId: panel.surface.id,
            expectedGeneration: panel.surface.portalBindingGeneration()
        )
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
        drainMainQueue()
        drainMainQueue()
        XCTAssertEqual(
            panel.surface.debugForceRefreshCount(),
            1,
            "The portal must perform exactly one deferred Dock reveal refresh"
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
        TerminalWindowPortalRegistry.bind(
            hostedView: panel.hostedView,
            to: anchor,
            visibleInUI: false,
            expectedSurfaceId: panel.surface.id,
            expectedGeneration: panel.surface.portalBindingGeneration()
        )
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
        drainMainQueue()
        drainMainQueue()
        XCTAssertEqual(
            panel.surface.debugForceRefreshCount(),
            1,
            "The portal must perform exactly one deferred text-box reveal refresh"
        )
    }

    @MainActor
    func testWorkspacePortalLookupStaysLiveWithDeepUnrelatedPanes() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let pane = try XCTUnwrap(workspace.paneId(forPanelId: panel.id))
        let tabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(panel.id))
        workspace.bonsplitController.focusPane(pane)
        workspace.bonsplitController.selectTab(tabId)

        let baselinePresentation = workspace.terminalPortalPresentation(panelId: panel.id, paneId: pane)
        XCTAssertEqual(workspace.bonsplitController.paneId(containing: tabId), pane)
        XCTAssertEqual(workspace.bonsplitController.selectedTabId(inPane: pane), tabId)

        workspace.isProgrammaticSplit = true
        defer { workspace.isProgrammaticSplit = false }
        for index in 0..<12 {
            XCTAssertNotNil(workspace.bonsplitController.splitPane(
                pane,
                orientation: .horizontal,
                withTab: Bonsplit.Tab(title: "unrelated-\(index)"),
                insertFirst: true,
                initialDividerPosition: nil
            ))
        }
        workspace.bonsplitController.focusPane(pane)
        workspace.bonsplitController.selectTab(tabId)

        let scaledPresentation = workspace.terminalPortalPresentation(panelId: panel.id, paneId: pane)
        XCTAssertEqual(workspace.bonsplitController.paneId(containing: tabId), pane)
        XCTAssertEqual(workspace.bonsplitController.selectedTabId(inPane: pane), tabId)
        XCTAssertEqual(scaledPresentation, baselinePresentation)
    }

    @MainActor
    func testWorkspacePortalSelectionRefreshesFromFocusOnlyTabClickCallback() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let firstPanel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let pane = try XCTUnwrap(workspace.paneId(forPanelId: firstPanel.id))
        let secondPanel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let secondTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(secondPanel.id))
        let controller = workspace.bonsplitController
        let owner = controller.delegate

        controller.delegate = nil
        controller.selectTab(secondTabId)
        controller.delegate = owner
        XCTAssertEqual(controller.selectedTabId(inPane: pane), secondTabId)
        workspace.splitTabBar(controller, didFocusPane: pane)

        XCTAssertEqual(
            workspace.terminalPortalPresentation(panelId: firstPanel.id, paneId: pane),
            .hidden
        )
        guard case .visible(_, let zPriority) = workspace.terminalPortalPresentation(
            panelId: secondPanel.id,
            paneId: pane
        ) else {
            XCTFail("The focus-only tab-click callback must expose the newly selected terminal")
            return
        }
        XCTAssertEqual(zPriority, 2)
    }

    @MainActor
    func testDockPortalLookupStaysLiveWithDeepUnrelatedPanes() throws {
        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { store.closeAllPanels() }
        let pane = try XCTUnwrap(store.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(store.newSurface(kind: .terminal, inPane: pane, focus: true))
        let tabId = try XCTUnwrap(store.surfaceId(forPanelId: panelId))
        store.setVisibleInUI(true)
        store.bonsplitController.focusPane(pane)
        store.bonsplitController.selectTab(tabId)

        let baselinePresentation = store.terminalPortalPresentation(
            panelId: panelId,
            tabId: tabId,
            paneId: pane
        )
        XCTAssertEqual(store.bonsplitController.paneId(containing: tabId), pane)
        XCTAssertEqual(store.bonsplitController.selectedTabId(inPane: pane), tabId)

        store.isProgrammaticDockSplit = true
        defer { store.isProgrammaticDockSplit = false }
        for index in 0..<12 {
            XCTAssertNotNil(store.bonsplitController.splitPane(
                pane,
                orientation: .horizontal,
                withTab: Bonsplit.Tab(title: "unrelated-\(index)"),
                insertFirst: true,
                initialDividerPosition: nil
            ))
        }
        store.bonsplitController.focusPane(pane)
        store.bonsplitController.selectTab(tabId)

        let scaledPresentation = store.terminalPortalPresentation(
            panelId: panelId,
            tabId: tabId,
            paneId: pane
        )
        XCTAssertEqual(store.bonsplitController.paneId(containing: tabId), pane)
        XCTAssertEqual(store.bonsplitController.selectedTabId(inPane: pane), tabId)
        XCTAssertEqual(scaledPresentation, baselinePresentation)
    }

    @MainActor
    func testRemoteTmuxPortalLookupStaysLiveWithDeepUnrelatedPanes() throws {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"),
            sessionName: "work"
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(7)),
            makePanel: { _ in nil }
        )
        let controller = mirror.bonsplitController
        let pane = try XCTUnwrap(controller.allPaneIds.first)
        let tabId = try XCTUnwrap(controller.createTab(title: "target", inPane: pane))
        controller.focusPane(pane)
        controller.selectTab(tabId)
        let outer = TerminalPortalPresentation.visible(isActive: true, zPriority: 2)
        let baseline = mirror.terminalPortalPresentation(
            tabId: tabId,
            paneId: pane,
            outerPresentation: outer
        )
        XCTAssertEqual(controller.paneId(containing: tabId), pane)
        XCTAssertEqual(controller.selectedTabId(inPane: pane), tabId)

        mirror.isApplyingRemoteLayout = true
        defer { mirror.isApplyingRemoteLayout = false }
        for index in 0..<12 {
            let sibling = Bonsplit.Tab(title: "unrelated-\(index)")
            XCTAssertNotNil(controller.splitPane(
                pane,
                orientation: .horizontal,
                withTab: sibling,
                insertFirst: true
            ))
        }
        controller.focusPane(pane)
        controller.selectTab(tabId)
        XCTAssertEqual(controller.paneId(containing: tabId), pane)
        XCTAssertEqual(controller.selectedTabId(inPane: pane), tabId)

        XCTAssertEqual(
            mirror.terminalPortalPresentation(
                tabId: tabId,
                paneId: pane,
                outerPresentation: outer
            ),
            baseline
        )
    }

    @MainActor
    func testTransientReattachDistinguishesAnnouncedAndOrphanedNilAnchors() async throws {
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
        let ownerHost = NSView()
        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(ownerHost),
            paneId: PaneID(),
            ownershipGeneration: 7,
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 360, height: 240),
            reason: "test.transient.owner"
        ))
        let recoveryGeneration = try XCTUnwrap(surface.preparePortalHostReplacementIfOwned(
            hostId: ObjectIdentifier(ownerHost),
            reason: "test.transient.prepare"
        ))
        portal.prepareEntryForTransientReattach(
            forHostedId: hostedId,
            ownershipGeneration: recoveryGeneration
        )
        entry = try XCTUnwrap(portal.entriesByHostedId[hostedId])
        entry.anchorView = nil
        portal.entriesByHostedId[hostedId] = entry
        portal.pruneDeadEntries()
        XCTAssertEqual(portal.debugEntryCount(), 1)

        let cleanup = try XCTUnwrap(portal.transientRecoveryExpiryTasksByHostedId[hostedId])
        await cleanup.value
        XCTAssertEqual(portal.debugEntryCount(), 0)
        XCTAssertTrue(surface.hostedView.isHidden)
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
