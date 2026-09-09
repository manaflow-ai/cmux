import AppKit
import Bonsplit
import CmuxCanvasUI
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class ShortcutUnrelatedResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class CanvasViewportSpy: CanvasViewportControlling {
    var revealedPanelIds: [UUID] = []
    var overviewToggleCount = 0
    var modelDidChangeCount = 0
    var resetZoomCount = 0
    var currentMagnification: CGFloat = 1
    var currentCenterInCanvas: CGPoint = .zero

    func revealPane(_ panelId: UUID, animated: Bool) { revealedPanelIds.append(panelId) }
    func toggleOverview() { overviewToggleCount += 1 }
    func zoom(by factor: CGFloat) {}
    func resetZoom() { resetZoomCount += 1 }
    func setViewport(center: CGPoint, magnification: CGFloat?) {}
    func modelDidChangeExternally(animated: Bool) { modelDidChangeCount += 1 }
}

@MainActor
@Suite(.serialized)
struct AppDelegateSurfaceShortcutRoutingTests {
    @Test func rightSidebarModeShortcutsDoNotFallThroughWhenResponderTemporarilyClears() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let panelId = try #require(workspace.focusedPanelId)
            let terminalPanel = try #require(workspace.terminalPanel(for: panelId))

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            terminalPanel.hostedView.setVisibleInUI(true)
            terminalPanel.hostedView.setActive(true)
            appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .sessions, in: window)

            let modeEvents: [(mode: RightSidebarMode, event: NSEvent)] = [
                (.files, try #require(makeKeyDownEvent(key: "1", keyCode: 18, windowNumber: window.windowNumber))),
                (.find, try #require(makeKeyDownEvent(key: "2", keyCode: 19, windowNumber: window.windowNumber))),
                (.sessions, try #require(makeKeyDownEvent(key: "3", keyCode: 20, windowNumber: window.windowNumber)))
            ]

            for cycle in 0..<10 {
                for (mode, event) in modeEvents {
                    _ = window.makeFirstResponder(nil)
#if DEBUG
                    #expect(
                        appDelegate.debugHandleCustomShortcut(event: event),
                        "Ctrl+\(event.charactersIgnoringModifiers ?? "?") should be handled on cycle \(cycle)"
                    )
#else
                    Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
                    #expect(
                        appDelegate.fileExplorerState?.mode == mode,
                        "Ctrl+\(event.charactersIgnoringModifiers ?? "?") should keep routing as a right-sidebar mode shortcut on cycle \(cycle)"
                    )
                    #expect(
                        !terminalPanel.hostedView.isSurfaceViewFirstResponder(),
                        "Ctrl+\(event.charactersIgnoringModifiers ?? "?") should not refocus the terminal on cycle \(cycle)"
                    )
                }
            }
        }
    }

    @Test func rightSidebarDockModeShortcutDoesNotClearTerminalUnread() async throws {
        try await withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let dock = appDelegate.windowDock(forWindowId: windowId)
            let paneId = try #require(dock.bonsplitController.allPaneIds.first)
            let panelId = try #require(dock.newSurface(
                kind: .terminal,
                inPane: paneId,
                focus: true
            ))
            let terminalPanel = try #require(dock.panels[panelId] as? TerminalPanel)
            let notificationStore = TerminalNotificationStore.shared
            let previousNotificationStore = appDelegate.notificationStore
            let event = try #require(makeKeyDownEvent(
                key: "1",
                keyCode: 18,
                windowNumber: window.windowNumber
            ))
            defer {
                notificationStore.clearWindowDockSurfaceUnread(
                    windowId: windowId,
                    surfaceId: panelId
                )
                appDelegate.notificationStore = previousNotificationStore
                terminalPanel.hostedView.removeFromSuperview()
            }

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            window.contentView?.addSubview(terminalPanel.hostedView)
            terminalPanel.hostedView.setVisibleInUI(true)
            terminalPanel.hostedView.setActive(true)
            #expect(window.makeFirstResponder(terminalPanel.hostedView.surfaceView))
            await startAndWaitForLiveSurface(terminalPanel.surface)
            #expect(window.makeFirstResponder(terminalPanel.hostedView.surfaceView))
            #expect(terminalPanel.hostedView.surfaceView.prepareSurfaceForPaste(
                reason: "test.rightSidebarModeShortcut"
            ))
            notificationStore.clearWindowDockSurfaceUnread(
                windowId: windowId,
                surfaceId: panelId
            )
            appDelegate.notificationStore = notificationStore
            dock.notificationStore = notificationStore
            #expect(notificationStore.markWindowDockSurfaceUnread(
                windowId: windowId,
                surfaceId: panelId
            ))
            #expect(appDelegate.rightSidebarModeShortcut(for: event) == .files)
            #expect(appDelegate.shouldRouteRightSidebarModeShortcut(in: window))

            terminalPanel.hostedView.surfaceView.keyDown(with: event)

            #expect(appDelegate.fileExplorerState?.mode == .files)
            #expect(notificationStore.hasManualUnread(
                forTabId: windowId,
                surfaceId: panelId
            ))
        }
    }

    @Test func keyboardCopyModeKeyClearsTerminalUnread() async throws {
        try await withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let panelId = try #require(workspace.focusedPanelId)
            let terminalPanel = try #require(workspace.terminalPanel(for: panelId))
            let surfaceView = terminalPanel.hostedView.surfaceView
            let event = try #require(makeKeyDownEvent(
                key: "j",
                modifiers: [],
                keyCode: 38,
                windowNumber: window.windowNumber
            ))

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            terminalPanel.hostedView.setVisibleInUI(true)
            terminalPanel.hostedView.setActive(true)
            #expect(window.makeFirstResponder(surfaceView))
            await startAndWaitForLiveSurface(terminalPanel.surface)
            #expect(surfaceView.prepareSurfaceForPaste(
                reason: "test.keyboardCopyModeKey"
            ))
            #expect(terminalPanel.surface.toggleKeyboardCopyMode())
            defer {
                if terminalPanel.surface.keyboardCopyModeActive {
                    _ = terminalPanel.surface.toggleKeyboardCopyMode()
                }
            }

            workspace.markPanelUnread(panelId)
            #expect(workspace.manualUnreadPanelIds.contains(panelId))

            surfaceView.keyDown(with: event)

            #expect(!workspace.manualUnreadPanelIds.contains(panelId))
        }
    }

    @Test func workspaceFontSizeShortcutPreservesBackgroundTerminalUnread() async throws {
        try await withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let foregroundPanelId = try #require(workspace.focusedPanelId)
            let foregroundPanel = try #require(workspace.terminalPanel(for: foregroundPanelId))
            let backgroundPanel = try #require(workspace.newTerminalSplit(
                from: foregroundPanelId,
                orientation: .horizontal,
                focus: false
            ))
            let event = try #require(makeKeyDownEvent(
                key: "-",
                modifiers: [.command, .control],
                keyCode: 27,
                windowNumber: window.windowNumber
            ))

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            foregroundPanel.hostedView.setVisibleInUI(true)
            foregroundPanel.hostedView.setActive(true)
            backgroundPanel.hostedView.setVisibleInUI(true)
            backgroundPanel.hostedView.setActive(false)
            await startAndWaitForLiveSurface(foregroundPanel.surface)
            await startAndWaitForLiveSurface(backgroundPanel.surface)
            #expect(foregroundPanel.surface.hasLiveSurface)
            #expect(backgroundPanel.surface.hasLiveSurface)

            workspace.focusPanel(foregroundPanelId)
            #expect(window.makeFirstResponder(foregroundPanel.hostedView.surfaceView))
            workspace.markPanelUnread(foregroundPanelId)
            workspace.markPanelUnread(backgroundPanel.id)
            #expect(workspace.manualUnreadPanelIds.contains(foregroundPanelId))
            #expect(workspace.manualUnreadPanelIds.contains(backgroundPanel.id))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(
                backgroundPanel.surface.fontSizeLineageSnapshot()?.isExplicitOverride == true,
                "The workspace-wide shortcut must reach the live background terminal"
            )
            #expect(
                !workspace.manualUnreadPanelIds.contains(foregroundPanelId),
                "The originating terminal must accept its handled shortcut"
            )
            #expect(
                workspace.manualUnreadPanelIds.contains(backgroundPanel.id),
                "Changing terminal configuration is not accepted terminal input"
            )
        }
    }

    @Test func rightSidebarModeShortcutsDoNotUseStaleIntentForUnrelatedResponder() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .sessions, in: window)
            let fileExplorerState = try #require(appDelegate.fileExplorerState)
            fileExplorerState.mode = .sessions

            let unrelatedResponder = ShortcutUnrelatedResponderView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
            window.contentView?.addSubview(unrelatedResponder)
            defer { unrelatedResponder.removeFromSuperview() }
            #expect(window.makeFirstResponder(unrelatedResponder))
            #expect(window.firstResponder === unrelatedResponder)

            KeyboardShortcutSettings.clearShortcut(for: .selectSurfaceByNumber)
#if DEBUG
            appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif

            let event = try #require(makeKeyDownEvent(key: "1", keyCode: 18, windowNumber: window.windowNumber))
#if DEBUG
            _ = appDelegate.debugHandleCustomShortcut(event: event)
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(
                fileExplorerState.mode == .sessions,
                "Ctrl+1 should not switch right-sidebar mode when a non-sidebar responder owns focus"
            )
            #expect(
                window.firstResponder === unrelatedResponder,
                "Ctrl+1 should not move focus away from the unrelated responder"
            )
        }
    }

    @Test func surfaceNumberShortcutsCycleInEventWindowWhenActiveManagerIsStale() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let firstWindowId = appDelegate.createMainWindow()
            let secondWindowId = appDelegate.createMainWindow()
            defer {
                closeWindow(withId: firstWindowId)
                closeWindow(withId: secondWindowId)
            }

            let firstManager = try #require(appDelegate.tabManagerFor(windowId: firstWindowId))
            let secondManager = try #require(appDelegate.tabManagerFor(windowId: secondWindowId))
            let secondWindow = try #require(mainWindow(for: secondWindowId))
            let firstWorkspace = try #require(firstManager.selectedWorkspace)
            let secondWorkspace = try #require(secondManager.selectedWorkspace)
            _ = try #require(secondWorkspace.newTerminalSurfaceInFocusedPane(focus: true))
            _ = try #require(secondWorkspace.newTerminalSurfaceInFocusedPane(focus: true))

            let expectedSurfaceIds = Array(secondWorkspace.orderedPanelIds.prefix(3))
            #expect(expectedSurfaceIds.count == 3, "Test needs three ordered surfaces")
            #expect(firstWorkspace.id != secondWorkspace.id)

            appDelegate.tabManager = firstManager
            #expect(appDelegate.tabManager === firstManager)

            let digitEvents: [(digit: Int, event: NSEvent)] = [
                (1, try #require(makeKeyDownEvent(key: "1", keyCode: 18, windowNumber: secondWindow.windowNumber))),
                (2, try #require(makeKeyDownEvent(key: "2", keyCode: 19, windowNumber: secondWindow.windowNumber))),
                (3, try #require(makeKeyDownEvent(key: "3", keyCode: 20, windowNumber: secondWindow.windowNumber)))
            ]

            try withTemporaryShortcut(action: .selectSurfaceByNumber) {
                for cycle in 0..<10 {
                    for (digit, event) in digitEvents {
#if DEBUG
                        #expect(
                            appDelegate.debugHandleCustomShortcut(event: event),
                            "Ctrl+\(digit) should be handled on cycle \(cycle)"
                        )
#else
                        Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
                        #expect(
                            secondWorkspace.focusedPanelId == expectedSurfaceIds[digit - 1],
                            "Ctrl+\(digit) should focus surface \(digit) in the event window on cycle \(cycle)"
                        )
                    }
                }
            }
        }
    }

    @Test func cmdShiftReturnInCanvasModeDoesNotToggleBonsplitSplitZoom() throws {
        try withTemporaryShortcut(action: .toggleSplitZoom) {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let leftPanelId = try #require(workspace.focusedPanelId)
            _ = try #require(workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal))
            let event = try #require(makeKeyDownEvent(
                key: "\r",
                modifiers: [.command, .shift],
                keyCode: 36,
                windowNumber: window.windowNumber
            ))

            workspace.setLayoutMode(.canvas)
            let viewport = CanvasViewportSpy()
            workspace.canvasModel.viewport = viewport
            #expect(workspace.layoutMode == .canvas)
            #expect(!workspace.bonsplitController.isSplitZoomed)
            #expect(KeyboardShortcutSettings.shortcut(for: .toggleSplitZoom).matches(event: event))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
            #expect(
                !workspace.bonsplitController.isSplitZoomed,
                "In canvas mode, the split-zoom shortcut should drive canvas overview instead of Bonsplit zoom"
            )
            #expect(viewport.overviewToggleCount == 1)
        }
    }

    @Test func cmdDInCanvasCreatesFloatingCanvasPaneWithoutBonsplitSplit() throws {
        try withTemporaryShortcut(action: .splitRight) {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let focusedPanelId = try #require(workspace.focusedPanelId)
            let event = try #require(makeKeyDownEvent(
                key: "d",
                modifiers: [.command],
                keyCode: 2,
                windowNumber: window.windowNumber
            ))

            window.makeKeyAndOrderFront(nil)
            workspace.setLayoutMode(.canvas)
            let originalBonsplitPaneCount = workspace.bonsplitController.allPaneIds.count
            let originalPanelIds = Set(workspace.panels.keys)
            let originalFrame = try #require(workspace.canvasModel.frame(of: focusedPanelId))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            let newPanelIds = Set(workspace.panels.keys).subtracting(originalPanelIds)
            #expect(newPanelIds.count == 1)
            #expect(
                workspace.bonsplitController.allPaneIds.count == originalBonsplitPaneCount,
                "Canvas split shortcuts should create visible canvas panes without splitting the hidden Bonsplit tree"
            )
            #expect(workspace.canvasModel.persistablePanes.count == 2)

            let newPanelId = try #require(newPanelIds.first)
            let newFrame = try #require(workspace.canvasModel.frame(of: newPanelId))
            #expect(newFrame.minX >= originalFrame.maxX)
            #expect(newFrame.width == originalFrame.width)
            #expect(newFrame.height == originalFrame.height)
            #expect(workspace.focusedPanelId == newPanelId)
        }
    }

    @Test func cmdShiftDInCanvasPlacesFloatingCanvasPaneBelowFocusedPane() throws {
        try withTemporaryShortcut(action: .splitDown) {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let focusedPanelId = try #require(workspace.focusedPanelId)
            let event = try #require(makeKeyDownEvent(
                key: "d",
                modifiers: [.command, .shift],
                keyCode: 2,
                windowNumber: window.windowNumber
            ))

            window.makeKeyAndOrderFront(nil)
            workspace.setLayoutMode(.canvas)
            let originalPanelIds = Set(workspace.panels.keys)
            let originalFrame = try #require(workspace.canvasModel.frame(of: focusedPanelId))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            let newPanelIds = Set(workspace.panels.keys).subtracting(originalPanelIds)
            #expect(newPanelIds.count == 1)
            let newPanelId = try #require(newPanelIds.first)
            let newFrame = try #require(workspace.canvasModel.frame(of: newPanelId))
            #expect(newFrame.minY >= originalFrame.maxY)
        }
    }

    @Test func numberedSurfaceShortcutSelectsCanvasPaneTab() throws {
        try withTemporaryShortcut(action: .selectSurfaceByNumber) {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let firstPanelId = try #require(workspace.focusedPanelId)
            let event = try #require(makeKeyDownEvent(
                key: "2",
                keyCode: 19,
                windowNumber: window.windowNumber
            ))

            window.makeKeyAndOrderFront(nil)
            workspace.setLayoutMode(.canvas)
            let secondPanelId = try #require(workspace.openNewCanvasPane(type: .terminal, focus: true))
            let viewport = CanvasViewportSpy()
            workspace.canvasModel.viewport = viewport
            workspace.focusPanel(firstPanelId)
            #expect(workspace.focusedPanelId == firstPanelId)

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(workspace.focusedPanelId == secondPanelId)
            #expect(viewport.revealedPanelIds.last == secondPanelId)
        }
    }

    @Test func canvasSurfaceSelectionKeepsNinthAndLastSeparate() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        var panelIds = [try #require(workspace.focusedPanelId)]

        workspace.setLayoutMode(.canvas)
        for _ in 1..<10 {
            panelIds.append(try #require(workspace.openNewCanvasPane(type: .terminal, focus: true)))
        }
        #expect(panelIds.count == 10)

        workspace.focusPanel(panelIds[0])
        workspace.selectSurface(at: 8)
        #expect(workspace.focusedPanelId == panelIds[8])

        workspace.selectLastSurface()
        #expect(workspace.focusedPanelId == panelIds[9])
    }

    @Test func equalizeSplitsShortcutInCanvasEqualizesCanvasPaneSizesOnly() throws {
        try withTemporaryShortcut(action: .equalizeSplits) {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let firstPanelId = try #require(workspace.focusedPanelId)
            let event = try #require(makeKeyDownEvent(
                key: "=",
                modifiers: [.command, .control, .shift],
                keyCode: 24,
                windowNumber: window.windowNumber
            ))

            window.makeKeyAndOrderFront(nil)
            workspace.setLayoutMode(.canvas)
            let secondPanelId = try #require(workspace.openNewCanvasPane(type: .terminal, focus: true))
            let originalBonsplitPaneCount = workspace.bonsplitController.allPaneIds.count
            workspace.canvasModel.setFrame(CGRect(x: 0, y: 0, width: 640, height: 420), for: firstPanelId)
            workspace.canvasModel.setFrame(CGRect(x: 720, y: 0, width: 320, height: 260), for: secondPanelId)

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            let firstFrame = try #require(workspace.canvasModel.frame(of: firstPanelId))
            let secondFrame = try #require(workspace.canvasModel.frame(of: secondPanelId))
            #expect(firstFrame.width == secondFrame.width)
            #expect(firstFrame.height == secondFrame.height)
            #expect(workspace.bonsplitController.allPaneIds.count == originalBonsplitPaneCount)
        }
    }

    @Test func paneResizeShortcutsAreInverseAndKeepNoCrossWorkspaceState() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let firstWorkspace = try #require(manager.selectedWorkspace)
            let firstPanelId = try #require(firstWorkspace.focusedPanelId)
            let rightPanel = try #require(
                firstWorkspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal)
            )
            let bottomPanel = try #require(
                firstWorkspace.newTerminalSplit(from: rightPanel.id, orientation: .vertical)
            )
            firstWorkspace.bonsplitController.setContainerFrame(
                CGRect(x: 0, y: 0, width: 900, height: 600)
            )
            firstWorkspace.focusPanel(bottomPanel.id)
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()

            let growWidthEvent = try #require(makeKeyDownEvent(
                key: "→",
                modifiers: [.command, .control],
                keyCode: 124,
                windowNumber: window.windowNumber
            ))
            let shrinkWidthEvent = try #require(makeKeyDownEvent(
                key: "←",
                modifiers: [.command, .control],
                keyCode: 123,
                windowNumber: window.windowNumber,
                isARepeat: true
            ))
            let growHeightEvent = try #require(makeKeyDownEvent(
                key: "↓",
                modifiers: [.command, .control],
                keyCode: 125,
                windowNumber: window.windowNumber
            ))
            let shrinkHeightEvent = try #require(makeKeyDownEvent(
                key: "↑",
                modifiers: [.command, .control],
                keyCode: 126,
                windowNumber: window.windowNumber,
                isARepeat: true
            ))
            let snapshot = firstWorkspace.bonsplitController.treeSnapshot()
            let widthSplitId = try #require(splitNodes(in: snapshot, orientation: "horizontal").first?.id)
            let heightSplitId = try #require(splitNodes(in: snapshot, orientation: "vertical").first?.id)
            let originalWidth = try #require(dividerPosition(of: widthSplitId, in: snapshot))
            let originalHeight = try #require(dividerPosition(of: heightSplitId, in: snapshot))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: growWidthEvent))
            #expect(appDelegate.debugHandleCustomShortcut(event: growWidthEvent))
            #expect(appDelegate.debugHandleCustomShortcut(event: growHeightEvent))
            #expect(appDelegate.debugHandleCustomShortcut(event: growHeightEvent))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
            let grownSnapshot = firstWorkspace.bonsplitController.treeSnapshot()
            let grownWidth = try #require(dividerPosition(of: widthSplitId, in: grownSnapshot))
            let grownHeight = try #require(dividerPosition(of: heightSplitId, in: grownSnapshot))
            #expect(abs(grownWidth - (originalWidth - (40.0 / 900.0))) < 0.000_1)
            #expect(abs(grownHeight - (originalHeight - (40.0 / 600.0))) < 0.000_1)
            #expect(firstWorkspace.focusedPanelId == bottomPanel.id)

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: shrinkWidthEvent))
            #expect(appDelegate.debugHandleCustomShortcut(event: shrinkWidthEvent))
            #expect(appDelegate.debugHandleCustomShortcut(event: shrinkHeightEvent))
            #expect(appDelegate.debugHandleCustomShortcut(event: shrinkHeightEvent))
#endif
            let restoredSnapshot = firstWorkspace.bonsplitController.treeSnapshot()
            let restoredWidth = try #require(dividerPosition(of: widthSplitId, in: restoredSnapshot))
            let restoredHeight = try #require(dividerPosition(of: heightSplitId, in: restoredSnapshot))
            #expect(abs(restoredWidth - originalWidth) < 0.000_1)
            #expect(abs(restoredHeight - originalHeight) < 0.000_1)

            firstWorkspace.isRemoteTmuxMirror = true
#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: growWidthEvent))
#endif
            let remoteMirrorSnapshot = firstWorkspace.bonsplitController.treeSnapshot()
            #expect(dividerPosition(of: widthSplitId, in: remoteMirrorSnapshot) == originalWidth)
            #expect(dividerPosition(of: heightSplitId, in: remoteMirrorSnapshot) == originalHeight)
            firstWorkspace.isRemoteTmuxMirror = false

            _ = manager.addWorkspace(select: true, eagerLoadTerminal: false)
#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: growWidthEvent))
#endif
            let unchangedSnapshot = firstWorkspace.bonsplitController.treeSnapshot()
            #expect(dividerPosition(of: widthSplitId, in: unchangedSnapshot) == originalWidth)
            #expect(dividerPosition(of: heightSplitId, in: unchangedSnapshot) == originalHeight)
        }
    }

    /// AppKit delivers real arrow keys as private-use function-key characters and
    /// adds `.function`/`.numericPad` to the modifier flags. Synthetic glyph-based
    /// events cannot prove the shortcuts fire on hardware, so this reproduces the
    /// hardware event shape end-to-end (PR #10532 review).
    @Test func paneResizeShortcutsMatchHardwareArrowEvents() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let firstPanelId = try #require(workspace.focusedPanelId)
            let rightPanel = try #require(
                workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal)
            )
            workspace.bonsplitController.setContainerFrame(
                CGRect(x: 0, y: 0, width: 900, height: 600)
            )
            workspace.focusPanel(rightPanel.id)
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()

            let snapshot = workspace.bonsplitController.treeSnapshot()
            let widthSplitId = try #require(splitNodes(in: snapshot, orientation: "horizontal").first?.id)
            let originalWidth = try #require(dividerPosition(of: widthSplitId, in: snapshot))

            let growWidthEvent = try #require(makeHardwareArrowKeyDownEvent(
                functionKey: NSRightArrowFunctionKey,
                keyCode: 124,
                modifiers: [.command, .control],
                windowNumber: window.windowNumber
            ))
            let shrinkWidthEvent = try #require(makeHardwareArrowKeyDownEvent(
                functionKey: NSLeftArrowFunctionKey,
                keyCode: 123,
                modifiers: [.command, .control],
                windowNumber: window.windowNumber
            ))

            // The event really does carry the flags the review flagged.
            #expect(growWidthEvent.modifierFlags.contains(.function))
            #expect(growWidthEvent.modifierFlags.contains(.numericPad))
            #expect(growWidthEvent.charactersIgnoringModifiers != "\u{2192}")

            #expect(appDelegate.matchConfiguredShortcut(event: growWidthEvent, action: .growPaneWidth))
            #expect(appDelegate.matchConfiguredShortcut(event: shrinkWidthEvent, action: .shrinkPaneWidth))
            #expect(!appDelegate.matchConfiguredShortcut(event: growWidthEvent, action: .shrinkPaneWidth))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: growWidthEvent))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
            let grownSnapshot = workspace.bonsplitController.treeSnapshot()
            let grownWidth = try #require(dividerPosition(of: widthSplitId, in: grownSnapshot))
            #expect(abs(grownWidth - (originalWidth - (20.0 / 900.0))) < 0.000_1)

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: shrinkWidthEvent))
#endif
            let restoredSnapshot = workspace.bonsplitController.treeSnapshot()
            let restoredWidth = try #require(dividerPosition(of: widthSplitId, in: restoredSnapshot))
            #expect(abs(restoredWidth - originalWidth) < 0.000_1)
        }
    }

    @Test func explicitLegacyBindingWinsOverImplicitPaneResizeDefault() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let paneCount = workspace.bonsplitController.allPaneIds.count
            let shortcut = StoredShortcut(
                key: "→",
                command: true,
                shift: false,
                option: false,
                control: true
            )
            KeyboardShortcutSettings.setShortcut(shortcut, for: .splitRight)
            let event = try #require(makeKeyDownEvent(
                key: "→",
                modifiers: [.command, .control],
                keyCode: 124,
                windowNumber: window.windowNumber
            ))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
            #expect(workspace.bonsplitController.allPaneIds.count == paneCount + 1)
        }
    }

    /// Builds the event shape AppKit delivers for a physical arrow key: the
    /// private-use function-key character plus `.function`/`.numericPad` flags.
    private func makeHardwareArrowKeyDownEvent(
        functionKey: Int,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        windowNumber: Int
    ) -> NSEvent? {
        guard let scalar = UnicodeScalar(functionKey) else { return nil }
        let characters = String(Character(scalar))
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers.union([.function, .numericPad]),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags = [.control],
        keyCode: UInt16,
        windowNumber: Int,
        isARepeat: Bool = false
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: isARepeat,
            keyCode: keyCode
        )
    }

    private func withTemporaryShortcut(action: KeyboardShortcutSettings.Action, _ body: () throws -> Void) rethrows {
        let hadPersistedShortcut = UserDefaults.standard.object(forKey: action.defaultsKey) != nil
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            if hadPersistedShortcut {
                KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
#if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        }
        KeyboardShortcutSettings.setShortcut(action.defaultShortcut, for: action)
#if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        try body()
    }

    private func withIsolatedShortcutSettings(_ body: () throws -> Void) rethrows {
        let actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        let savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-surface-shortcut-routing"
        )
        KeyboardShortcutSettings.resetAll()
#if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            for action in KeyboardShortcutSettings.Action.allCases {
                if actionsWithPersistedShortcut.contains(action),
                   let savedShortcut = savedShortcutsByAction[action] {
                    KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
                } else {
                    KeyboardShortcutSettings.resetShortcut(for: action)
                }
            }
#if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        }
        try body()
    }

    private func withIsolatedShortcutSettings(
        _ body: () async throws -> Void
    ) async rethrows {
        let actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        let savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-surface-shortcut-routing"
        )
        KeyboardShortcutSettings.resetAll()
#if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            for action in KeyboardShortcutSettings.Action.allCases {
                if actionsWithPersistedShortcut.contains(action),
                   let savedShortcut = savedShortcutsByAction[action] {
                    KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
                } else {
                    KeyboardShortcutSettings.resetShortcut(for: action)
                }
            }
#if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        }
        try await body()
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

    private func mainWindow(for windowId: UUID) -> NSWindow? {
        AppDelegate.shared?.windowForMainWindowId(windowId)
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = mainWindow(for: windowId) else { return }
        window.close()
    }

    private func splitNodes(
        in node: ExternalTreeNode,
        orientation: String
    ) -> [ExternalSplitNode] {
        switch node {
        case .pane:
            return []
        case .split(let split):
            let descendants = splitNodes(in: split.first, orientation: orientation)
                + splitNodes(in: split.second, orientation: orientation)
            return split.orientation == orientation ? [split] + descendants : descendants
        }
    }

    private func dividerPosition(of splitId: String, in node: ExternalTreeNode) -> Double? {
        switch node {
        case .pane:
            return nil
        case .split(let split):
            if split.id == splitId {
                return split.dividerPosition
            }
            return dividerPosition(of: splitId, in: split.first)
                ?? dividerPosition(of: splitId, in: split.second)
        }
    }
}
