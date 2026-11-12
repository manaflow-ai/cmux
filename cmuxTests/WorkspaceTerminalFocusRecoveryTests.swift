import AppKit
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceTerminalFocusRecoverySwiftTests {
#if DEBUG
    @Test
    func hiddenTinyFirstResponderReappliesGhosttyFocusAfterGeometrySettles() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let originalAppDelegate = AppDelegate.shared
            let appDelegate = originalAppDelegate ?? AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let originalTabManager = appDelegate.tabManager
            let window = makeWindow()
            defer { window.orderOut(nil) }
            let windowId = UUID()
            AppDelegate.shared = appDelegate
            appDelegate.registerMainWindow(
                window,
                windowId: windowId,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: FileExplorerState()
            )
            appDelegate.tabManager = manager
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                manager.finalizeAllWorkspacesForWindowClose()
                appDelegate.tabManager = originalTabManager
                AppDelegate.shared = originalAppDelegate
            }

            let workspace = try #require(manager.selectedWorkspace, "Expected initial workspace")
            manager.selectWorkspace(workspace)
            workspace.setPortalRenderingEnabled(true, reason: "focus-recovery-test")
            let panelId = try #require(workspace.focusedPanelId, "Expected initial focused panel")
            let panel = try #require(workspace.terminalPanel(for: panelId), "Expected initial terminal panel")
            let contentView = try #require(window.contentView, "Expected content view")

            panel.hostedView.frame = contentView.bounds
            contentView.addSubview(panel.hostedView)
            panel.hostedView.setVisibleInUI(true)
            panel.hostedView.setActive(true)

            window.makeKeyAndOrderFront(nil)
            appDelegate.setActiveMainWindow(window)
            window.displayIfNeeded()
            contentView.layoutSubtreeIfNeeded()
            panel.hostedView.layoutSubtreeIfNeeded()
            await AppKitTestEventPump().startSurface(panel.surface)
            panel.hostedView.reconcileGeometryNow()
            try #require(panel.surface.hasLiveSurface)
            await AppKitTestEventPump().drain()

            let surfaceView = try #require(findSurfaceView(in: panel.hostedView), "Expected terminal surface view")

            window.makeFirstResponder(nil)
            panel.surface.setFocus(false)
            #expect(!panel.surface.debugDesiredFocusState())

            surfaceView.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
            #expect(window.makeFirstResponder(surfaceView))
            _ = await AppKitTestEventPump().waitUntil { panel.hostedView.isSurfaceViewFirstResponder() }
            #expect(panel.hostedView.isSurfaceViewFirstResponder())
            #expect(panel.hostedView.debugRenderStats().desiredFocus)
            #expect(
                !panel.surface.debugDesiredFocusState(),
                "Hidden/tiny first-responder handoff should defer Ghostty focus until geometry is usable"
            )

            // Run the deferred apply's body in this turn, against the same 0x0 surface. A drain
            // here let the window's layout pass restore the surface first on macOS 26 CI, and
            // the apply then correctly focused usable geometry.
            surfaceView.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
            panel.hostedView.debugApplyFirstResponderNowForTesting()
            #expect(
                !panel.surface.debugDesiredFocusState(),
                "The first deferred apply can fire while geometry is still unusable"
            )

            surfaceView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
            surfaceView.layoutSubtreeIfNeeded()
            await AppKitTestEventPump().drain()

            _ = await AppKitTestEventPump().waitUntil { panel.surface.debugDesiredFocusState() }
            #expect(
                panel.surface.debugDesiredFocusState(),
                "Deferred focus reconciliation should reapply Ghostty focus once geometry becomes usable"
            )
        }
    }

    @Test
    func forcedReparentFocusClearRetriesWhenSurfaceGeometryIsStillTiny() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let originalAppDelegate = AppDelegate.shared
            let appDelegate = originalAppDelegate ?? AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let originalTabManager = appDelegate.tabManager
            let window = makeWindow()
            defer { window.orderOut(nil) }
            let windowId = UUID()
            AppDelegate.shared = appDelegate
            appDelegate.registerMainWindow(
                window,
                windowId: windowId,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: FileExplorerState()
            )
            appDelegate.tabManager = manager
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                manager.finalizeAllWorkspacesForWindowClose()
                appDelegate.tabManager = originalTabManager
                AppDelegate.shared = originalAppDelegate
            }

            let workspace = try #require(manager.selectedWorkspace, "Expected initial workspace")
            manager.selectWorkspace(workspace)
            workspace.setPortalRenderingEnabled(true, reason: "focus-recovery-test")
            let panelId = try #require(workspace.focusedPanelId, "Expected initial focused panel")
            let panel = try #require(workspace.terminalPanel(for: panelId), "Expected initial terminal panel")
            let contentView = try #require(window.contentView, "Expected content view")

            panel.hostedView.frame = contentView.bounds
            contentView.addSubview(panel.hostedView)
            panel.hostedView.setVisibleInUI(true)
            panel.hostedView.setActive(true)

            window.makeKeyAndOrderFront(nil)
            appDelegate.setActiveMainWindow(window)
            window.displayIfNeeded()
            contentView.layoutSubtreeIfNeeded()
            panel.hostedView.layoutSubtreeIfNeeded()
            await AppKitTestEventPump().startSurface(panel.surface)
            panel.hostedView.reconcileGeometryNow()
            try #require(panel.surface.hasLiveSurface)
            await AppKitTestEventPump().drain()

            let surfaceView = try #require(findSurfaceView(in: panel.hostedView), "Expected terminal surface view")

            window.makeFirstResponder(nil)
            panel.surface.setFocus(false)
            surfaceView.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
            panel.hostedView.suppressReparentFocus()
            #expect(panel.hostedView.debugIsSuppressingReparentFocusForTesting())
            #expect(window.makeFirstResponder(surfaceView))
            try #require(panel.hostedView.debugHasPendingAutomaticFirstResponderApplyForTesting())
            // Run the queued reapply now against the 0x0 surface. A drain let the window's layout
            // pass restore the surface first on macOS 26 CI, and the reapply then focused it.
            surfaceView.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
            panel.hostedView.debugApplyFirstResponderNowForTesting()
            #expect(!panel.surface.debugDesiredFocusState())

            panel.hostedView.clearSuppressReparentFocus()

            #expect(
                panel.hostedView.debugHasPendingSuppressedFirstResponderFocusReapplyForTesting(),
                "Forced reparent focus reassert should keep a deferred retry queued while surface geometry is tiny"
            )
            #expect(!panel.surface.debugDesiredFocusState())

            surfaceView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
            await AppKitTestEventPump().drain()

            _ = await AppKitTestEventPump().waitUntil { panel.surface.debugDesiredFocusState() }
            #expect(
                panel.surface.debugDesiredFocusState(),
                "Forced reparent focus reassert should recover once the queued retry sees usable surface geometry"
            )
        }
    }

    @Test
    func alreadyFirstResponderReparentFocusClearWaitsForSurfaceGeometry() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let originalAppDelegate = AppDelegate.shared
            let appDelegate = originalAppDelegate ?? AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let originalTabManager = appDelegate.tabManager
            let window = makeWindow()
            defer { window.orderOut(nil) }
            let windowId = UUID()
            AppDelegate.shared = appDelegate
            appDelegate.registerMainWindow(
                window,
                windowId: windowId,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: FileExplorerState()
            )
            appDelegate.tabManager = manager
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                manager.finalizeAllWorkspacesForWindowClose()
                appDelegate.tabManager = originalTabManager
                AppDelegate.shared = originalAppDelegate
            }

            let workspace = try #require(manager.selectedWorkspace, "Expected initial workspace")
            manager.selectWorkspace(workspace)
            workspace.setPortalRenderingEnabled(true, reason: "focus-recovery-test")
            let panelId = try #require(workspace.focusedPanelId, "Expected initial focused panel")
            let panel = try #require(workspace.terminalPanel(for: panelId), "Expected initial terminal panel")
            let contentView = try #require(window.contentView, "Expected content view")

            panel.hostedView.frame = contentView.bounds
            contentView.addSubview(panel.hostedView)
            panel.hostedView.setVisibleInUI(true)
            panel.hostedView.setActive(true)

            window.makeKeyAndOrderFront(nil)
            appDelegate.setActiveMainWindow(window)
            window.displayIfNeeded()
            contentView.layoutSubtreeIfNeeded()
            panel.hostedView.layoutSubtreeIfNeeded()
            await AppKitTestEventPump().startSurface(panel.surface)
            panel.hostedView.reconcileGeometryNow()
            try #require(panel.surface.hasLiveSurface)
            await AppKitTestEventPump().drain()

            let surfaceView = try #require(findSurfaceView(in: panel.hostedView), "Expected terminal surface view")

            #expect(window.makeFirstResponder(surfaceView))
            _ = await AppKitTestEventPump().waitUntil { panel.hostedView.isSurfaceViewFirstResponder() }
            #expect(panel.hostedView.isSurfaceViewFirstResponder())
            panel.surface.setFocus(false)
            #expect(!panel.surface.debugDesiredFocusState())

            surfaceView.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
            panel.hostedView.suppressReparentFocus()
            panel.hostedView.clearSuppressReparentFocus()

            #expect(
                panel.hostedView.debugHasPendingAutomaticFirstResponderApplyForTesting(),
                "Already-first-responder reparent clear should queue a retry instead of focusing a tiny surface"
            )
            #expect(!panel.surface.debugDesiredFocusState())

            surfaceView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
            await AppKitTestEventPump().drain()

            _ = await AppKitTestEventPump().waitUntil { panel.surface.debugDesiredFocusState() }
            #expect(
                panel.surface.debugDesiredFocusState(),
                "Already-first-responder reparent clear should recover after surface geometry becomes usable"
            )
        }
    }

    @Test
    func automaticApplyDoesNotBypassHiddenTinyFirstResponderDeferral() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let originalAppDelegate = AppDelegate.shared
            let appDelegate = originalAppDelegate ?? AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let originalTabManager = appDelegate.tabManager
            let window = makeWindow()
            defer { window.orderOut(nil) }
            let windowId = UUID()
            AppDelegate.shared = appDelegate
            appDelegate.registerMainWindow(
                window,
                windowId: windowId,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: FileExplorerState()
            )
            appDelegate.tabManager = manager
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                manager.finalizeAllWorkspacesForWindowClose()
                appDelegate.tabManager = originalTabManager
                AppDelegate.shared = originalAppDelegate
            }

            let workspace = try #require(manager.selectedWorkspace, "Expected initial workspace")
            manager.selectWorkspace(workspace)
            workspace.setPortalRenderingEnabled(true, reason: "focus-recovery-test")
            let panelId = try #require(workspace.focusedPanelId, "Expected initial focused panel")
            let panel = try #require(workspace.terminalPanel(for: panelId), "Expected initial terminal panel")
            let contentView = try #require(window.contentView, "Expected content view")
            appDelegate.noteMainPanelKeyboardFocusIntent(
                workspaceId: workspace.id, panelId: panelId, in: window
            )

            panel.hostedView.frame = contentView.bounds
            contentView.addSubview(panel.hostedView)
            panel.hostedView.setVisibleInUI(false)
            panel.hostedView.setActive(true)

            window.makeKeyAndOrderFront(nil)
            appDelegate.setActiveMainWindow(window)
            window.displayIfNeeded()
            contentView.layoutSubtreeIfNeeded()
            panel.hostedView.layoutSubtreeIfNeeded()
            await AppKitTestEventPump().startSurface(panel.surface)
            panel.hostedView.reconcileGeometryNow()
            try #require(panel.surface.hasLiveSurface)
            await AppKitTestEventPump().drain()

            let surfaceView = try #require(findSurfaceView(in: panel.hostedView), "Expected terminal surface view")

            window.makeFirstResponder(nil)
            panel.surface.setFocus(false)
            // Only a hidden-to-visible transition schedules the automatic apply. The panel can be
            // visible again after setup, which would turn the reveal below into a no-op.
            panel.hostedView.setVisibleInUI(false)
            try #require(!panel.hostedView.debugPortalVisibleInUI, "The reveal below must start from a hidden panel")

            panel.hostedView.setVisibleInUI(true)
            try #require(panel.hostedView.debugPortalVisibleInUI, "Portal authority should let the selected workspace's panel reveal")
            try #require(
                panel.hostedView.debugHasPendingAutomaticFirstResponderApplyForTesting(),
                "The reveal should queue the automatic first-responder apply"
            )

            // Run that apply against a 0x0 surface in this same turn. Left on the queue, the
            // reveal's layout pass can resize the surface back to the portal first (seen on
            // macOS 26 CI), and the apply then correctly focuses a usable surface.
            surfaceView.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
            panel.hostedView.debugApplyFirstResponderNowForTesting()
            #expect(
                panel.hostedView.debugHasPendingSuppressedFirstResponderFocusReapplyForTesting(),
                "The apply should leave a hidden/tiny deferral pending for geometry recovery"
            )
            #expect(
                panel.hostedView.isSurfaceViewFirstResponder(),
                "First responder after the reveal: \(String(describing: window.firstResponder))"
            )
            #expect(panel.hostedView.debugRenderStats().desiredFocus)
            #expect(
                !panel.surface.debugDesiredFocusState(),
                "Automatic first-responder apply must not mark Ghostty focused while hidden/tiny deferral is pending"
            )

            surfaceView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
            surfaceView.layoutSubtreeIfNeeded()
            panel.hostedView.layoutSubtreeIfNeeded()
            await AppKitTestEventPump().drain()

            _ = await AppKitTestEventPump().waitUntil { panel.surface.debugDesiredFocusState() }
            #expect(
                panel.surface.debugDesiredFocusState(),
                "Pending automatic deferral should reapply Ghostty focus once the surface geometry is usable"
            )
        }
    }

    @Test
    func findTerminalRestorePreservesHiddenTinyFirstResponderDeferral() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let originalAppDelegate = AppDelegate.shared
            let appDelegate = originalAppDelegate ?? AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let originalTabManager = appDelegate.tabManager
            let window = makeWindow()
            defer { window.orderOut(nil) }
            let windowId = UUID()
            AppDelegate.shared = appDelegate
            appDelegate.registerMainWindow(
                window,
                windowId: windowId,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: FileExplorerState()
            )
            appDelegate.tabManager = manager
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                manager.finalizeAllWorkspacesForWindowClose()
                appDelegate.tabManager = originalTabManager
                AppDelegate.shared = originalAppDelegate
            }

            let workspace = try #require(manager.selectedWorkspace, "Expected initial workspace")
            manager.selectWorkspace(workspace)
            workspace.setPortalRenderingEnabled(true, reason: "focus-recovery-test")
            let panelId = try #require(workspace.focusedPanelId, "Expected initial focused panel")
            let panel = try #require(workspace.terminalPanel(for: panelId), "Expected initial terminal panel")
            let contentView = try #require(window.contentView, "Expected content view")
            appDelegate.noteMainPanelKeyboardFocusIntent(
                workspaceId: workspace.id, panelId: panelId, in: window
            )

            panel.hostedView.frame = contentView.bounds
            contentView.addSubview(panel.hostedView)
            panel.hostedView.setVisibleInUI(false)
            panel.hostedView.setActive(true)

            let searchState = TerminalSurface.SearchState(needle: "needle")
            panel.surface.searchState = searchState
            panel.hostedView.setSearchOverlay(searchState: searchState)
            panel.hostedView.preparePanelFocusIntentForActivation(.surface)

            window.makeKeyAndOrderFront(nil)
            appDelegate.setActiveMainWindow(window)
            window.displayIfNeeded()
            contentView.layoutSubtreeIfNeeded()
            panel.hostedView.layoutSubtreeIfNeeded()
            await AppKitTestEventPump().startSurface(panel.surface)
            panel.hostedView.reconcileGeometryNow()
            try #require(panel.surface.hasLiveSurface)
            await AppKitTestEventPump().drain()

            let surfaceView = try #require(findSurfaceView(in: panel.hostedView), "Expected terminal surface view")

            // Put the panel on screen so the find overlay mounts its search field.
            panel.hostedView.setVisibleInUI(true)
            var mountedSearchField: NSTextField?
            let searchFieldMounted = await AppKitTestEventPump().waitUntil(timeout: .seconds(3)) {
                mountedSearchField = findMountedSearchField(in: panel.hostedView)
                return mountedSearchField != nil
            }
            try #require(searchFieldMounted, "Expected the find overlay to mount its search field")
            let searchField = try #require(mountedSearchField)
            // Re-applying the mounted state bumps the overlay generation, which cancels the
            // mount's remaining forced field-focus retries.
            panel.hostedView.setSearchOverlay(searchState: searchState)
            // The overlay's focus binding starts out set, and only the field's end-editing callback
            // clears it. Let the field hold focus once and then resign it, so the overlay has no
            // pending claim on focus when the panel reveals.
            if !cmuxTextFieldIsFirstResponder(searchField, in: window) {
                window.makeFirstResponder(searchField)
            }
            await AppKitTestEventPump().drain()
            try #require(cmuxTextFieldIsFirstResponder(searchField, in: window), "Expected the find field to take focus")

            window.makeFirstResponder(nil)
            // The restore under test: the terminal, not the find field, is the panel's focus intent.
            panel.hostedView.preparePanelFocusIntentForActivation(.surface)
            panel.surface.setFocus(false)
            await AppKitTestEventPump().drain()

            // Only a hidden-to-visible transition schedules the automatic apply.
            panel.hostedView.setVisibleInUI(false)
            try #require(!panel.hostedView.debugPortalVisibleInUI, "The reveal below must start from a hidden panel")

            panel.hostedView.setVisibleInUI(true)
            try #require(panel.hostedView.debugPortalVisibleInUI, "Portal authority should let the selected workspace's panel reveal")
            try #require(
                panel.hostedView.debugHasPendingAutomaticFirstResponderApplyForTesting(),
                "The reveal should queue the automatic first-responder apply"
            )

            // Run that apply against a 0x0 surface in this same turn. Left on the queue, the
            // reveal's layout pass can resize the surface back to the portal first (seen on
            // macOS 26 CI), and the apply then correctly focuses a usable surface.
            surfaceView.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
            panel.hostedView.debugApplyFirstResponderNowForTesting()
            #expect(
                panel.hostedView.debugHasPendingSuppressedFirstResponderFocusReapplyForTesting(),
                "The apply should leave a hidden/tiny deferral pending for geometry recovery"
            )
            #expect(
                panel.hostedView.isSurfaceViewFirstResponder(),
                "First responder after the reveal: \(String(describing: window.firstResponder))"
            )
            #expect(
                !panel.surface.debugDesiredFocusState(),
                "Find terminal restore must not drop hidden/tiny focus recovery before Ghostty focus is reapplied"
            )

            surfaceView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
            surfaceView.layoutSubtreeIfNeeded()
            panel.hostedView.layoutSubtreeIfNeeded()
            await AppKitTestEventPump().drain()

            _ = await AppKitTestEventPump().waitUntil { panel.surface.debugDesiredFocusState() }
            #expect(
                panel.surface.debugDesiredFocusState(),
                "Find terminal restore should reassert Ghostty focus after deferred geometry recovery"
            )
        }
    }

    @Test
    func rightSidebarDockHiddenTinyFirstResponderReappliesGhosttyFocusAfterGeometrySettles() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let originalAppDelegate = AppDelegate.shared
            AppDelegate.shared = nil
            defer { AppDelegate.shared = originalAppDelegate }

            let panel = TerminalPanel(
                workspaceId: UUID(),
                focusPlacement: .rightSidebarDock
            )
            let window = makeWindow()
            defer { window.orderOut(nil) }
            let contentView = try #require(window.contentView, "Expected content view")

            panel.hostedView.frame = contentView.bounds
            contentView.addSubview(panel.hostedView)
            panel.hostedView.setVisibleInUI(true)
            panel.hostedView.setActive(true)

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            contentView.layoutSubtreeIfNeeded()
            panel.hostedView.layoutSubtreeIfNeeded()
            await AppKitTestEventPump().startSurface(panel.surface)
            panel.hostedView.reconcileGeometryNow()
            try #require(panel.surface.hasLiveSurface)
            await AppKitTestEventPump().drain()

            let surfaceView = try #require(findSurfaceView(in: panel.hostedView), "Expected terminal surface view")

            window.makeFirstResponder(nil)
            panel.surface.setFocus(false)
            #expect(!panel.surface.debugDesiredFocusState())

            surfaceView.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
            #expect(window.makeFirstResponder(surfaceView))
            _ = await AppKitTestEventPump().waitUntil { panel.hostedView.isSurfaceViewFirstResponder() }
            #expect(panel.hostedView.isSurfaceViewFirstResponder())
            #expect(panel.hostedView.debugRenderStats().desiredFocus)
            #expect(
                !panel.surface.debugDesiredFocusState(),
                "Right-sidebar dock handoff should defer Ghostty focus until geometry is usable"
            )

            await AppKitTestEventPump().drain()
            #expect(
                !panel.surface.debugDesiredFocusState(),
                "The dock deferred apply can fire while geometry is still unusable"
            )

            surfaceView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
            surfaceView.layoutSubtreeIfNeeded()
            panel.hostedView.layoutSubtreeIfNeeded()
            await AppKitTestEventPump().drain()

            _ = await AppKitTestEventPump().waitUntil { panel.surface.debugDesiredFocusState() }
            #expect(
                panel.surface.debugDesiredFocusState(),
                "Right-sidebar dock deferred focus reconciliation should reapply Ghostty focus once geometry becomes usable"
            )
        }
    }

    @Test
    func rightSidebarDockAutomaticVisibilityApplyDoesNotStealMainTerminalFocus() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let originalAppDelegate = AppDelegate.shared
            AppDelegate.shared = nil
            defer { AppDelegate.shared = originalAppDelegate }

            let mainPanel = TerminalPanel(workspaceId: UUID())
            let dockPanel = TerminalPanel(
                workspaceId: UUID(),
                focusPlacement: .rightSidebarDock
            )
            let window = makeWindow()
            defer { window.orderOut(nil) }
            let contentView = try #require(window.contentView, "Expected content view")

            mainPanel.hostedView.frame = contentView.bounds
            dockPanel.hostedView.frame = contentView.bounds
            contentView.addSubview(mainPanel.hostedView)
            contentView.addSubview(dockPanel.hostedView)
            mainPanel.hostedView.setVisibleInUI(true)
            mainPanel.hostedView.setActive(true)
            dockPanel.hostedView.setVisibleInUI(false)
            dockPanel.hostedView.setActive(true)

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            contentView.layoutSubtreeIfNeeded()
            mainPanel.hostedView.layoutSubtreeIfNeeded()
            dockPanel.hostedView.layoutSubtreeIfNeeded()
            await AppKitTestEventPump().drain()

            let mainSurfaceView = try #require(findSurfaceView(in: mainPanel.hostedView), "Expected main terminal surface view")
            _ = try #require(findSurfaceView(in: dockPanel.hostedView), "Expected dock terminal surface view")

            #expect(window.makeFirstResponder(mainSurfaceView))
            #expect(window.firstResponder === mainSurfaceView)
            dockPanel.surface.setFocus(false)
            #expect(!dockPanel.surface.debugDesiredFocusState())

            dockPanel.hostedView.setVisibleInUI(true)
            dockPanel.hostedView.layoutSubtreeIfNeeded()
            await AppKitTestEventPump().drain()

            #expect(window.firstResponder === mainSurfaceView)
            #expect(!dockPanel.hostedView.debugRenderStats().desiredFocus)
            #expect(
                !dockPanel.surface.debugDesiredFocusState(),
                "Dock visibility/readiness applies must not steal keyboard focus without an active hidden/tiny handoff"
            )
        }
    }
#endif

    private func makeWindow() -> NSWindow {
        KeyStatusTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    private func findSurfaceView(in hostedView: GhosttySurfaceScrollView) -> GhosttyNSView? {
        var stack: [NSView] = [hostedView]
        while let current = stack.popLast() {
            if let surfaceView = current as? GhosttyNSView {
                return surfaceView
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

#if DEBUG
    private func findMountedSearchField(in hostedView: GhosttySurfaceScrollView) -> NSTextField? {
        guard let overlay = hostedView.debugSearchOverlayHostingViewForTesting() else { return nil }
        var stack: [NSView] = [overlay]
        while let current = stack.popLast() {
            if let field = current as? NSTextField, field.isEditable {
                return field
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }
#endif
}
