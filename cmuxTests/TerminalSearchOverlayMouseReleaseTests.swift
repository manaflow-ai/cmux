import AppKit
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal search overlay mouse release", .serialized)
struct TerminalSearchOverlayMouseReleaseTests {
    @Test("Search overlay forwards terminal mouse release during selection drag")
    func searchOverlayForwardsTerminalMouseReleaseDuringSelectionDrag() async throws {
        try await withFocusedTerminal { surface, hostedView, window in
            hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "needle"))
            #expect(await AppKitTestEventPump().waitUntil {
                hostedView.debugHasSearchOverlay() && surface.surface != nil
            })

            let terminalView = try #require(surfaceView(in: hostedView) as? GhosttyNSView)
            let overlay = try #require(hostedView.debugSearchOverlayHostingViewForTesting())
            // The terminal must already own workspace focus before the press
            // so this gesture selects text instead of only activating the pane.
            terminalView.desiredFocus = true
            try #require(terminalView.terminalPointerShouldForwardActivation())

            let downLocation = terminalView.convert(NSPoint(x: 24, y: 24), to: nil)
            terminalView.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: downLocation, window: window))
            #expect(
                hostedView.debugSurfaceHasPendingLeftMouseReleaseForTesting(),
                "Terminal selection should own the left-button release after mouseDown"
            )

            let overlayLocation = overlay.convert(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY), to: nil)
            overlay.mouseDragged(with: makeMouseEvent(type: .leftMouseDragged, location: overlayLocation, window: window))
            #expect(
                hostedView.debugSurfaceHasPendingLeftMouseReleaseForTesting(),
                "Dragging across the find overlay must keep terminal selection ownership until mouseUp"
            )

            overlay.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: overlayLocation, window: window))
            #expect(
                !hostedView.debugSurfaceHasPendingLeftMouseReleaseForTesting(),
                "An overlay-captured mouseUp must release the terminal selection"
            )
        }
    }

    @Test("Search overlay release clears pending selection after surface release")
    func searchOverlayMouseReleaseClearsSelectionDragAfterSurfaceRelease() async throws {
        try await withFocusedTerminal { surface, hostedView, window in
            hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "needle"))
            #expect(await AppKitTestEventPump().waitUntil {
                hostedView.debugHasSearchOverlay() && surface.surface != nil
            })

            let terminalView = try #require(surfaceView(in: hostedView) as? GhosttyNSView)
            let overlay = try #require(hostedView.debugSearchOverlayHostingViewForTesting())
            terminalView.desiredFocus = true
            try #require(terminalView.terminalPointerShouldForwardActivation())

            let downLocation = terminalView.convert(NSPoint(x: 24, y: 24), to: nil)
            terminalView.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: downLocation, window: window))
            #expect(hostedView.debugSurfaceHasPendingLeftMouseReleaseForTesting())

            surface.releaseSurfaceForTesting()
            #expect(surface.surface == nil)

            let overlayLocation = overlay.convert(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY), to: nil)
            overlay.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: overlayLocation, window: window))
            #expect(
                !hostedView.debugSurfaceHasPendingLeftMouseReleaseForTesting(),
                "The pending terminal release state must clear even if the Ghostty surface is gone"
            )
        }
    }

    private func withFocusedTerminal(
        _ body: (TerminalSurface, GhosttySurfaceScrollView, NSWindow) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            defer {
                manager.tabs.forEach { $0.teardownAllPanels() }
                TerminalController.shared.setActiveTabManager(previousManager)
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.selectedWorkspace)
            let panel = try #require(workspace.focusedTerminalPanel)
            let (hostedView, window) = try attachToWindow(surface: panel.surface)
            let windowID = UUID()
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
            appDelegate.registerMainWindow(
                window,
                windowId: windowID,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState()
            )
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                window.orderOut(nil)
                window.close()
            }
            hostedView.setVisibleInUI(true)
            hostedView.setActive(true)
            await AppKitTestEventPump().startSurface(panel.surface)
            hostedView.reconcileGeometryNow()
            _ = try #require(panel.surface.surface)
            appDelegate.noteMainPanelKeyboardFocusIntent(workspaceId: workspace.id, panelId: panel.id, in: window)
            workspace.focusPanel(panel.id, focusIntent: .terminal(.surface))
            #expect(workspace.isFocusedTerminalInputSurface(panel.id))

            try await body(panel.surface, hostedView, window)
        }
    }

    private func attachToWindow(surface: TerminalSurface) throws -> (GhosttySurfaceScrollView, NSWindow) {
        let hostedView = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let contentView = try #require(window.contentView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        return (hostedView, window)
    }

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            preconditionFailure("Failed to create \(type) mouse event")
        }
        return event
    }

    private func surfaceView(in hostedView: GhosttySurfaceScrollView) -> NSView? {
        hostedView.subviews
            .compactMap { $0 as? NSScrollView }
            .first?
            .documentView?
            .subviews
            .first
    }

}
