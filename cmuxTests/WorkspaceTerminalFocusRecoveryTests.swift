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
    func hiddenTinyFirstResponderReappliesGhosttyFocusAfterGeometrySettles() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = originalAppDelegate ?? AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let originalTabManager = appDelegate.tabManager
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            appDelegate.tabManager = originalTabManager
            AppDelegate.shared = originalAppDelegate
        }

        let workspace = try #require(manager.selectedWorkspace, "Expected initial workspace")
        let panelId = try #require(workspace.focusedPanelId, "Expected initial focused panel")
        let panel = try #require(workspace.terminalPanel(for: panelId), "Expected initial terminal panel")
        workspace.focusPanel(panelId, trigger: .terminalFirstResponder)

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
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let surfaceView = try #require(findSurfaceView(in: panel.hostedView), "Expected terminal surface view")

        window.makeFirstResponder(nil)
        panel.surface.setFocus(false)
        #expect(!panel.surface.debugDesiredFocusState())

        surfaceView.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        #expect(window.makeFirstResponder(surfaceView))
        #expect(panel.hostedView.isSurfaceViewFirstResponder())
        #expect(panel.hostedView.debugRenderStats().desiredFocus)
        #expect(
            !panel.surface.debugDesiredFocusState(),
            "Hidden/tiny first-responder handoff should defer Ghostty focus until geometry is usable"
        )

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(
            !panel.surface.debugDesiredFocusState(),
            "The first deferred apply can fire while geometry is still unusable"
        )

        surfaceView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
        surfaceView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        #expect(
            panel.surface.debugDesiredFocusState(),
            "Deferred focus reconciliation should reapply Ghostty focus once geometry becomes usable"
        )
    }

    @Test
    func forcedReparentFocusClearRetriesWhenSurfaceGeometryIsStillTiny() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = originalAppDelegate ?? AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let originalTabManager = appDelegate.tabManager
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            appDelegate.tabManager = originalTabManager
            AppDelegate.shared = originalAppDelegate
        }

        let workspace = try #require(manager.selectedWorkspace, "Expected initial workspace")
        let panelId = try #require(workspace.focusedPanelId, "Expected initial focused panel")
        let panel = try #require(workspace.terminalPanel(for: panelId), "Expected initial terminal panel")
        workspace.focusPanel(panelId, trigger: .terminalFirstResponder)

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
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let surfaceView = try #require(findSurfaceView(in: panel.hostedView), "Expected terminal surface view")

        window.makeFirstResponder(nil)
        panel.surface.setFocus(false)
        surfaceView.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        panel.hostedView.suppressReparentFocus()
        #expect(panel.hostedView.debugIsSuppressingReparentFocusForTesting())
        #expect(window.makeFirstResponder(surfaceView))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(!panel.hostedView.debugHasPendingAutomaticFirstResponderApplyForTesting())
        #expect(!panel.surface.debugDesiredFocusState())

        panel.hostedView.clearSuppressReparentFocus()

        #expect(
            panel.hostedView.debugHasPendingAutomaticFirstResponderApplyForTesting(),
            "Forced reparent focus reassert should keep a deferred retry queued while surface geometry is tiny"
        )
        #expect(!panel.surface.debugDesiredFocusState())

        surfaceView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        #expect(
            panel.surface.debugDesiredFocusState(),
            "Forced reparent focus reassert should recover once the queued retry sees usable surface geometry"
        )
    }

    @Test
    func alreadyFirstResponderReparentFocusClearWaitsForSurfaceGeometry() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = originalAppDelegate ?? AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let originalTabManager = appDelegate.tabManager
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            appDelegate.tabManager = originalTabManager
            AppDelegate.shared = originalAppDelegate
        }

        let workspace = try #require(manager.selectedWorkspace, "Expected initial workspace")
        let panelId = try #require(workspace.focusedPanelId, "Expected initial focused panel")
        let panel = try #require(workspace.terminalPanel(for: panelId), "Expected initial terminal panel")
        workspace.focusPanel(panelId, trigger: .terminalFirstResponder)

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
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let surfaceView = try #require(findSurfaceView(in: panel.hostedView), "Expected terminal surface view")

        #expect(window.makeFirstResponder(surfaceView))
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        #expect(
            panel.surface.debugDesiredFocusState(),
            "Already-first-responder reparent clear should recover after surface geometry becomes usable"
        )
    }

    @Test
    func automaticApplyDoesNotBypassHiddenTinyFirstResponderDeferral() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = originalAppDelegate ?? AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let originalTabManager = appDelegate.tabManager
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            appDelegate.tabManager = originalTabManager
            AppDelegate.shared = originalAppDelegate
        }

        let workspace = try #require(manager.selectedWorkspace, "Expected initial workspace")
        let panelId = try #require(workspace.focusedPanelId, "Expected initial focused panel")
        let panel = try #require(workspace.terminalPanel(for: panelId), "Expected initial terminal panel")
        workspace.focusPanel(panelId, trigger: .terminalFirstResponder)

        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView, "Expected content view")

        panel.hostedView.frame = contentView.bounds
        contentView.addSubview(panel.hostedView)
        panel.hostedView.setVisibleInUI(false)
        panel.hostedView.setActive(true)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        panel.hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let surfaceView = try #require(findSurfaceView(in: panel.hostedView), "Expected terminal surface view")

        window.makeFirstResponder(nil)
        panel.surface.setFocus(false)
        surfaceView.frame = NSRect(x: 0, y: 0, width: 0, height: 0)

        panel.hostedView.setVisibleInUI(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        #expect(panel.hostedView.isSurfaceViewFirstResponder())
        #expect(panel.hostedView.debugRenderStats().desiredFocus)
        #expect(
            !panel.surface.debugDesiredFocusState(),
            "Automatic first-responder apply must not mark Ghostty focused while hidden/tiny deferral is pending"
        )

        surfaceView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
        surfaceView.layoutSubtreeIfNeeded()
        panel.hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        #expect(
            panel.surface.debugDesiredFocusState(),
            "Pending automatic deferral should reapply Ghostty focus once the surface geometry is usable"
        )
    }

    @Test
    func findTerminalRestorePreservesHiddenTinyFirstResponderDeferral() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = originalAppDelegate ?? AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let originalTabManager = appDelegate.tabManager
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            appDelegate.tabManager = originalTabManager
            AppDelegate.shared = originalAppDelegate
        }

        let workspace = try #require(manager.selectedWorkspace, "Expected initial workspace")
        let panelId = try #require(workspace.focusedPanelId, "Expected initial focused panel")
        let panel = try #require(workspace.terminalPanel(for: panelId), "Expected initial terminal panel")
        workspace.focusPanel(panelId, trigger: .terminalFirstResponder)

        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView, "Expected content view")

        panel.hostedView.frame = contentView.bounds
        contentView.addSubview(panel.hostedView)
        panel.hostedView.setVisibleInUI(false)
        panel.hostedView.setActive(true)

        let searchState = TerminalSurface.SearchState(needle: "needle")
        panel.surface.searchState = searchState
        panel.hostedView.setSearchOverlay(searchState: searchState)
        panel.hostedView.preparePanelFocusIntentForActivation(.surface)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        panel.hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let surfaceView = try #require(findSurfaceView(in: panel.hostedView), "Expected terminal surface view")

        window.makeFirstResponder(nil)
        panel.surface.setFocus(false)
        surfaceView.frame = NSRect(x: 0, y: 0, width: 0, height: 0)

        panel.hostedView.setVisibleInUI(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        #expect(panel.hostedView.isSurfaceViewFirstResponder())
        #expect(
            !panel.surface.debugDesiredFocusState(),
            "Find terminal restore must not drop hidden/tiny focus recovery before Ghostty focus is reapplied"
        )

        surfaceView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
        surfaceView.layoutSubtreeIfNeeded()
        panel.hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        #expect(
            panel.surface.debugDesiredFocusState(),
            "Find terminal restore should reassert Ghostty focus after deferred geometry recovery"
        )
    }

    @Test
    func rightSidebarDockHiddenTinyFirstResponderReappliesGhosttyFocusAfterGeometrySettles() throws {
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let surfaceView = try #require(findSurfaceView(in: panel.hostedView), "Expected terminal surface view")

        window.makeFirstResponder(nil)
        panel.surface.setFocus(false)
        #expect(!panel.surface.debugDesiredFocusState())

        surfaceView.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        #expect(window.makeFirstResponder(surfaceView))
        #expect(panel.hostedView.isSurfaceViewFirstResponder())
        #expect(panel.hostedView.debugRenderStats().desiredFocus)
        #expect(
            !panel.surface.debugDesiredFocusState(),
            "Right-sidebar dock handoff should defer Ghostty focus until geometry is usable"
        )

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(
            !panel.surface.debugDesiredFocusState(),
            "The dock deferred apply can fire while geometry is still unusable"
        )

        surfaceView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
        surfaceView.layoutSubtreeIfNeeded()
        panel.hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        #expect(
            panel.surface.debugDesiredFocusState(),
            "Right-sidebar dock deferred focus reconciliation should reapply Ghostty focus once geometry becomes usable"
        )
    }

    @Test
    func rightSidebarDockAutomaticVisibilityApplyDoesNotStealMainTerminalFocus() throws {
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let mainSurfaceView = try #require(findSurfaceView(in: mainPanel.hostedView), "Expected main terminal surface view")
        _ = try #require(findSurfaceView(in: dockPanel.hostedView), "Expected dock terminal surface view")

        #expect(window.makeFirstResponder(mainSurfaceView))
        #expect(window.firstResponder === mainSurfaceView)
        dockPanel.surface.setFocus(false)
        #expect(!dockPanel.surface.debugDesiredFocusState())

        dockPanel.hostedView.setVisibleInUI(true)
        dockPanel.hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        #expect(window.firstResponder === mainSurfaceView)
        #expect(!dockPanel.hostedView.debugRenderStats().desiredFocus)
        #expect(
            !dockPanel.surface.debugDesiredFocusState(),
            "Dock visibility/readiness applies must not steal keyboard focus without an active hidden/tiny handoff"
        )
    }
#endif

    private func makeWindow() -> NSWindow {
        NSWindow(
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
}
