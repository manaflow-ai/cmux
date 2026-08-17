import AppKit
import Bonsplit
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Dock terminal pointer focus", .serialized)
struct DockTerminalPointerFocusTests {
    @Test("Pointer-down activates the owning Dock pane without a portal callback")
    func pointerDownActivatesOwningDockPaneWithoutPortalCallback() async throws {
#if DEBUG
        try await AppContextSerialGate.withExclusiveAppContext {
            try await exercisePointerDownActivation()
        }
#else
        Issue.record("Ghostty pointer-focus coverage is only available in DEBUG")
#endif
    }

    @Test("Right-click applies terminal focus before a cold runtime exists")
    func rightClickAppliesTerminalFocusBeforeColdRuntimeExists() async throws {
#if DEBUG
        try await AppContextSerialGate.withExclusiveAppContext {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            let contentView = NSView(frame: window.contentLayoutRect)
            window.contentView = contentView
            let panel = TerminalPanel(
                workspaceId: UUID(),
                focusPlacement: .rightSidebarDock,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            let surfaceView = GhosttyNSView(frame: contentView.bounds)
            surfaceView.terminalSurface = panel.surface
            contentView.addSubview(surfaceView)
            window.makeKeyAndOrderFront(nil)
            defer {
                panel.close()
                window.orderOut(nil)
                window.close()
            }

            var focusRequestCount = 0
            var acceptedInputCount = 0
            surfaceView.onFocus = { focusRequestCount += 1 }
            panel.surface.onExplicitInput = { acceptedInputCount += 1 }
            #expect(!panel.surface.hasLiveSurface)

            surfaceView.rightMouseDown(with: try mouseDownEvent(
                type: .rightMouseDown,
                at: NSPoint(x: 24, y: 24),
                window: window
            ))

            #expect(focusRequestCount == 1)
            #expect(window.firstResponder === surfaceView)
            #expect(acceptedInputCount == 1)
        }
#else
        Issue.record("Ghostty pointer-focus coverage is only available in DEBUG")
#endif
    }

#if DEBUG
    private func exercisePointerDownActivation() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let fileExplorerState = FileExplorerState()
        let notificationStore = TerminalNotificationStore.shared
        let previousNotificationStore = appDelegate.notificationStore
        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")

        AppDelegate.shared = appDelegate
        appDelegate.notificationStore = notificationStore
        notificationStore.markRead(forTabId: windowId)
        appDelegate.tabManager = manager
        appDelegate.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: fileExplorerState
        )
        window.makeKeyAndOrderFront(nil)
        defer {
            notificationStore.markRead(forTabId: windowId)
            appDelegate.notificationStore = previousNotificationStore
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            window.orderOut(nil)
            window.close()
            AppDelegate.shared = previousAppDelegate
        }

        let dock = appDelegate.windowDock(forWindowId: windowId)
        dock.setVisibleInUI(true)
        defer { dock.setVisibleInUI(false) }

        let firstPanel = TerminalPanel(
            workspaceId: windowId,
            focusPlacement: .rightSidebarDock
        )
        let secondPanel = TerminalPanel(
            workspaceId: windowId,
            focusPlacement: .rightSidebarDock
        )
        try seedSplitDock(dock, firstPanel: firstPanel, secondPanel: secondPanel)
        dock.focusPanel(firstPanel.id)
        #expect(dock.focusedPanelId == firstPanel.id)

        let mainWorkspace = try #require(manager.selectedWorkspace)
        let mainPanel = try #require(mainWorkspace.focusedTerminalPanel)
        mainWorkspace.focusPanel(mainPanel.id)

        let contentView = try #require(window.contentView)
        let halfWidth = contentView.bounds.width / 2
        mainPanel.hostedView.frame = NSRect(
            x: 0,
            y: 0,
            width: halfWidth,
            height: contentView.bounds.height
        )
        secondPanel.hostedView.frame = NSRect(
            x: halfWidth,
            y: 0,
            width: halfWidth,
            height: contentView.bounds.height
        )
        contentView.addSubview(mainPanel.hostedView)
        contentView.addSubview(secondPanel.hostedView)
        mainPanel.hostedView.setVisibleInUI(true)
        mainPanel.hostedView.setActive(true)
        secondPanel.hostedView.setVisibleInUI(true)
        secondPanel.hostedView.setActive(false)

        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        mainPanel.hostedView.layoutSubtreeIfNeeded()
        secondPanel.hostedView.layoutSubtreeIfNeeded()

        let mainSurfaceView = try #require(waitForSurfaceView(in: mainPanel.hostedView))
        let surfaceView = try #require(waitForSurfaceView(in: secondPanel.hostedView))
        #expect(window.makeFirstResponder(mainSurfaceView))
        appDelegate.noteMainPanelKeyboardFocusIntent(
            workspaceId: mainWorkspace.id,
            panelId: mainPanel.id,
            in: window
        )

        let pointInWindow = surfaceView.convert(NSPoint(x: 24, y: 24), to: nil)
        surfaceView.mouseDown(with: try mouseDownEvent(at: pointInWindow, window: window))

        #expect(dock.focusedPanelId == secondPanel.id)
        #expect(window.firstResponder === surfaceView)
        #expect(appDelegate.focusedDockStoreForShortcut(preferredWindow: window) === dock)
        #expect(secondPanel.hostedView.debugRenderStats().isActive)

        dock.installAttentionRouting(for: secondPanel)
        await startAndWaitForLiveSurface(secondPanel.surface)
        let runtimeSurface = try #require(secondPanel.surface.surface)
        Data("\u{1b}[?1000h".utf8).withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?
                .assumingMemoryBound(to: CChar.self) else {
                return
            }
            ghostty_surface_process_output(
                runtimeSurface,
                baseAddress,
                UInt(rawBuffer.count)
            )
        }
        #expect(ghostty_surface_mouse_captured(runtimeSurface))
        dock.focusPanel(firstPanel.id)
        _ = window.makeFirstResponder(mainSurfaceView)
        appDelegate.noteMainPanelKeyboardFocusIntent(
            workspaceId: mainWorkspace.id,
            panelId: mainPanel.id,
            in: window
        )
        #expect(notificationStore.markWindowDockSurfaceUnread(
            windowId: windowId,
            surfaceId: secondPanel.id
        ))

        surfaceView.rightMouseDown(with: try mouseDownEvent(
            type: .rightMouseDown,
            at: pointInWindow,
            window: window
        ))

        #expect(dock.focusedPanelId == secondPanel.id)
        #expect(!notificationStore.hasManualUnread(
            forTabId: windowId,
            surfaceId: secondPanel.id
        ))
    }

    fileprivate func exerciseDockSelectionAndRestoration() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let fileExplorerState = FileExplorerState()
        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")

        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        appDelegate.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: fileExplorerState
        )
        window.makeKeyAndOrderFront(nil)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            window.orderOut(nil)
            window.close()
            AppDelegate.shared = previousAppDelegate
        }

        let dock = appDelegate.windowDock(forWindowId: windowId)
        dock.setVisibleInUI(true)
        defer { dock.setVisibleInUI(false) }

        let topPanel = TerminalPanel(
            workspaceId: windowId,
            focusPlacement: .rightSidebarDock
        )
        let bottomPanel = TerminalPanel(
            workspaceId: windowId,
            focusPlacement: .rightSidebarDock
        )
        try seedSplitDock(dock, firstPanel: topPanel, secondPanel: bottomPanel)
        dock.focusPanel(topPanel.id)

        let mainWorkspace = try #require(manager.selectedWorkspace)
        let mainPanel = try #require(mainWorkspace.focusedTerminalPanel)
        mainWorkspace.focusPanel(mainPanel.id)

        let contentView = try #require(window.contentView)
        let halfWidth = contentView.bounds.width / 2
        let halfHeight = contentView.bounds.height / 2
        mainPanel.hostedView.frame = NSRect(
            x: 0,
            y: 0,
            width: halfWidth,
            height: contentView.bounds.height
        )
        bottomPanel.hostedView.frame = NSRect(
            x: halfWidth,
            y: 0,
            width: halfWidth,
            height: halfHeight
        )
        topPanel.hostedView.frame = NSRect(
            x: halfWidth,
            y: halfHeight,
            width: halfWidth,
            height: halfHeight
        )
        contentView.addSubview(mainPanel.hostedView)
        contentView.addSubview(topPanel.hostedView)
        contentView.addSubview(bottomPanel.hostedView)
        mainPanel.hostedView.setVisibleInUI(true)
        mainPanel.hostedView.setActive(true)
        topPanel.hostedView.setVisibleInUI(true)
        topPanel.hostedView.setActive(false)
        bottomPanel.hostedView.setVisibleInUI(true)
        bottomPanel.hostedView.setActive(false)

        let dockFocusHost = DockKeyboardFocusView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        dockFocusHost.focusFirstControl = { dock.focusFirstControl() }
        contentView.addSubview(dockFocusHost)
        dockFocusHost.registerWithKeyboardFocusCoordinatorIfNeeded()
        defer { dockFocusHost.removeFromSuperview() }

        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        mainPanel.hostedView.layoutSubtreeIfNeeded()
        topPanel.hostedView.layoutSubtreeIfNeeded()
        bottomPanel.hostedView.layoutSubtreeIfNeeded()

        let mainSurfaceView = try #require(waitForSurfaceView(in: mainPanel.hostedView))
        let bottomSurfaceView = try #require(waitForSurfaceView(in: bottomPanel.hostedView))
        #expect(window.makeFirstResponder(mainSurfaceView))
        appDelegate.noteMainPanelKeyboardFocusIntent(
            workspaceId: mainWorkspace.id,
            panelId: mainPanel.id,
            in: window
        )

        dock.focusPanelFromDockInteraction(bottomPanel.id, window: window)

        #expect(dock.focusedPanelId == bottomPanel.id)
        #expect(window.firstResponder === bottomSurfaceView)

        #expect(window.makeFirstResponder(nil))
        let focusController = try #require(appDelegate.keyboardFocusCoordinator(for: window))
        #expect(focusController.restoreTargetAfterWindowBecameKey())

        #expect(dock.focusedPanelId == bottomPanel.id)
        #expect(window.firstResponder === bottomSurfaceView)
    }
#endif

    private func seedSplitDock(
        _ dock: DockSplitStore,
        firstPanel: TerminalPanel,
        secondPanel: TerminalPanel
    ) throws {
        let firstPane = try #require(dock.bonsplitController.allPaneIds.first)
        let firstTab = try #require(dock.bonsplitController.createTab(
            title: firstPanel.displayTitle,
            icon: firstPanel.displayIcon,
            kind: "terminal",
            isDirty: false,
            inPane: firstPane
        ))
        dock.panels[firstPanel.id] = firstPanel
        dock.bindSurface(firstTab, toPanelId: firstPanel.id)

        let secondTab = Bonsplit.Tab(
            title: secondPanel.displayTitle,
            icon: secondPanel.displayIcon,
            kind: "terminal",
            isDirty: false
        )
        dock.panels[secondPanel.id] = secondPanel
        dock.bindSurface(secondTab.id, toPanelId: secondPanel.id)
        let secondPane = dock.withProgrammaticDockSplit {
            dock.bonsplitController.splitPane(
                firstPane,
                orientation: .horizontal,
                withTab: secondTab,
                insertFirst: false
            )
        }
        _ = try #require(secondPane)
    }

    private func findSurfaceView(in hostedView: GhosttySurfaceScrollView) -> GhosttyNSView? {
        var pending: [NSView] = [hostedView]
        while let view = pending.popLast() {
            if let surfaceView = view as? GhosttyNSView {
                return surfaceView
            }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func waitForSurfaceView(
        in hostedView: GhosttySurfaceScrollView,
        timeout: TimeInterval = 2
    ) -> GhosttyNSView? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let surfaceView = findSurfaceView(in: hostedView),
               surfaceView.window != nil,
               surfaceView.bounds.width > 1,
               surfaceView.bounds.height > 1 {
                return surfaceView
            }
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.01))
        }
        return nil
    }

    private func startAndWaitForLiveSurface(_ surface: TerminalSurface) async {
        guard !surface.hasLiveSurface else { return }
        let previousOnRuntimeReady = surface.onRuntimeReady
        defer { surface.onRuntimeReady = previousOnRuntimeReady }
        let readiness = AsyncStream<Void> { continuation in
            surface.onRuntimeReady = {
                previousOnRuntimeReady?()
                continuation.yield()
                continuation.finish()
            }
        }
        surface.requestInputDemandSurfaceStartIfNeeded()
        for await _ in readiness { break }
    }

    private func mouseDownEvent(
        type: NSEvent.EventType = .leftMouseDown,
        at point: NSPoint,
        window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}

@MainActor
@Suite("Dock terminal selection focus", .serialized)
struct DockTerminalSelectionFocusTests {
    @Test("Dock selection and restoration keep first responder on the selected terminal")
    func dockSelectionAndRestorationKeepSelectedTerminalFirstResponder() async throws {
#if DEBUG
        try await AppContextSerialGate.withExclusiveAppContext {
            try DockTerminalPointerFocusTests()
                .exerciseDockSelectionAndRestoration()
        }
#else
        Issue.record("Ghostty Dock focus coverage is only available in DEBUG")
#endif
    }
}
