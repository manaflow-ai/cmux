import AppKit
import Testing

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

        let surfaceView = try #require(surfaceView(in: panel.hostedView), "Expected terminal surface view")

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

        let surfaceView = try #require(surfaceView(in: panel.hostedView), "Expected terminal surface view")

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

        let surfaceView = try #require(surfaceView(in: panel.hostedView), "Expected terminal surface view")

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
#endif

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    private func surfaceView(in hostedView: GhosttySurfaceScrollView) -> GhosttyNSView? {
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
