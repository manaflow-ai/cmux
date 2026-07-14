import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AppDelegateSurfaceShortcutRoutingTests {
    @Test func surfaceMoveShortcutsReorderSelectedSurfaceAndPreserveFocus() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        let window = try #require(mainWindow(for: windowId))
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let firstPanelId = try #require(workspace.focusedPanelId)
        let secondPanel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: true))
        let thirdPanel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: true))
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let panelOrder = {
            workspace.bonsplitController.tabs(inPane: paneId).compactMap {
                workspace.panelIdFromSurfaceId($0.id)
            }
        }

        window.makeKeyAndOrderFront(nil)
        workspace.focusPanel(secondPanel.id)
        #expect(panelOrder() == [firstPanelId, secondPanel.id, thirdPanel.id])

        let moveLeft = StoredShortcut(key: "h", command: true, shift: true, option: true, control: true)
        let moveLeftEvent = try #require(makeKeyDownEvent(
            key: "h",
            modifiers: [.command, .shift, .option, .control],
            keyCode: 4,
            windowNumber: window.windowNumber
        ))
        try withTemporaryShortcut(action: .moveSurfaceLeft, shortcut: moveLeft) {
#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: moveLeftEvent))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
        #expect(panelOrder() == [secondPanel.id, firstPanelId, thirdPanel.id])
        #expect(workspace.focusedPanelId == secondPanel.id)

        let moveRight = StoredShortcut(key: "l", command: true, shift: true, option: true, control: true)
        let moveRightEvent = try #require(makeKeyDownEvent(
            key: "l",
            modifiers: [.command, .shift, .option, .control],
            keyCode: 37,
            windowNumber: window.windowNumber
        ))
        try withTemporaryShortcut(action: .moveSurfaceRight, shortcut: moveRight) {
#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: moveRightEvent))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
        #expect(panelOrder() == [firstPanelId, secondPanel.id, thirdPanel.id])
        #expect(workspace.focusedPanelId == secondPanel.id)
    }

    @Test func surfaceMoveShortcutsUseCanvasTabOrderWithoutMutatingHiddenSplitOrder() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        let window = try #require(mainWindow(for: windowId))
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let firstPanelId = try #require(workspace.focusedPanelId)

        window.makeKeyAndOrderFront(nil)
        workspace.setLayoutMode(.canvas)
        let secondPanelId = try #require(workspace.openNewCanvasPane(type: .terminal, focus: true))
        let thirdPanelId = try #require(workspace.openNewCanvasPane(type: .terminal, focus: true))
        #expect(workspace.canvasModel.joinPanel(secondPanelId, withPaneContaining: firstPanelId))
        #expect(workspace.canvasModel.joinPanel(thirdPanelId, withPaneContaining: firstPanelId))
        workspace.focusPanel(secondPanelId)

        let splitPaneId = try #require(workspace.bonsplitController.focusedPaneId)
        let originalSplitOrder = workspace.bonsplitController.tabs(inPane: splitPaneId).map(\.id)
        #expect(workspace.canvasModel.panelIds(inPaneContaining: firstPanelId) == [
            firstPanelId,
            secondPanelId,
            thirdPanelId,
        ])

        let viewport = CanvasViewportSpy()
        workspace.canvasModel.viewport = viewport
        let moveLeft = StoredShortcut(key: "h", command: true, shift: true, option: true, control: true)
        let moveLeftEvent = try #require(makeKeyDownEvent(
            key: "h",
            modifiers: [.command, .shift, .option, .control],
            keyCode: 4,
            windowNumber: window.windowNumber
        ))
        try withTemporaryShortcut(action: .moveSurfaceLeft, shortcut: moveLeft) {
#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: moveLeftEvent))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
        #expect(workspace.canvasModel.panelIds(inPaneContaining: firstPanelId) == [
            secondPanelId,
            firstPanelId,
            thirdPanelId,
        ])
        #expect(workspace.focusedPanelId == secondPanelId)
        #expect(workspace.bonsplitController.tabs(inPane: splitPaneId).map(\.id) == originalSplitOrder)

        let moveRight = StoredShortcut(key: "l", command: true, shift: true, option: true, control: true)
        let moveRightEvent = try #require(makeKeyDownEvent(
            key: "l",
            modifiers: [.command, .shift, .option, .control],
            keyCode: 37,
            windowNumber: window.windowNumber
        ))
        try withTemporaryShortcut(action: .moveSurfaceRight, shortcut: moveRight) {
#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: moveRightEvent))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
        #expect(workspace.canvasModel.panelIds(inPaneContaining: firstPanelId) == [
            firstPanelId,
            secondPanelId,
            thirdPanelId,
        ])
        #expect(workspace.focusedPanelId == secondPanelId)
        #expect(workspace.bonsplitController.tabs(inPane: splitPaneId).map(\.id) == originalSplitOrder)
        #expect(viewport.modelDidChangeCount == 2)
    }

    @Test func workspaceMoveShortcutsReorderSelectedWorkspaceAndPreserveSelection() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        let window = try #require(mainWindow(for: windowId))
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let firstWorkspace = try #require(manager.selectedWorkspace)
        let secondWorkspace = manager.addTab(select: false)
        let thirdWorkspace = manager.addTab(select: false)

        window.makeKeyAndOrderFront(nil)
        manager.selectWorkspace(secondWorkspace)
        #expect(manager.tabs.map(\.id) == [firstWorkspace.id, secondWorkspace.id, thirdWorkspace.id])

        let moveUp = StoredShortcut(key: "k", command: true, shift: true, option: true, control: true)
        let moveUpEvent = try #require(makeKeyDownEvent(
            key: "k",
            modifiers: [.command, .shift, .option, .control],
            keyCode: 40,
            windowNumber: window.windowNumber
        ))
        try withTemporaryShortcut(action: .moveWorkspaceUp, shortcut: moveUp) {
#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: moveUpEvent))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
        #expect(manager.tabs.map(\.id) == [secondWorkspace.id, firstWorkspace.id, thirdWorkspace.id])
        #expect(manager.selectedWorkspace?.id == secondWorkspace.id)

        let moveDown = StoredShortcut(key: "j", command: true, shift: true, option: true, control: true)
        let moveDownEvent = try #require(makeKeyDownEvent(
            key: "j",
            modifiers: [.command, .shift, .option, .control],
            keyCode: 38,
            windowNumber: window.windowNumber
        ))
        try withTemporaryShortcut(action: .moveWorkspaceDown, shortcut: moveDown) {
#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: moveDownEvent))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
        #expect(manager.tabs.map(\.id) == [firstWorkspace.id, secondWorkspace.id, thirdWorkspace.id])
        #expect(manager.selectedWorkspace?.id == secondWorkspace.id)
    }

    @Test func reorderShortcutsDoNotMutateMainWindowFromAuxiliaryWindowEvent() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let firstWorkspace = try #require(manager.selectedWorkspace)
        let secondWorkspace = manager.addTab(select: false)
        manager.selectWorkspace(secondWorkspace)
        let firstPanelId = try #require(secondWorkspace.focusedPanelId)
        let secondPanel = try #require(secondWorkspace.newTerminalSurfaceInFocusedPane(focus: true))
        let paneId = try #require(secondWorkspace.bonsplitController.focusedPaneId)
        let originalWorkspaceOrder = manager.tabs.map(\.id)
        let originalSurfaceOrder = secondWorkspace.bonsplitController.tabs(inPane: paneId).map(\.id)
        appDelegate.tabManager = manager

        let auxiliaryWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        auxiliaryWindow.isReleasedWhenClosed = false
        auxiliaryWindow.animationBehavior = .none
        auxiliaryWindow.identifier = NSUserInterfaceItemIdentifier("cmux.about")
        auxiliaryWindow.makeKeyAndOrderFront(nil)
        defer { auxiliaryWindow.close() }

        let moveWorkspace = StoredShortcut(key: "k", command: true, shift: true, option: true, control: true)
        let moveWorkspaceEvent = try #require(makeKeyDownEvent(
            key: "k",
            modifiers: [.command, .shift, .option, .control],
            keyCode: 40,
            windowNumber: auxiliaryWindow.windowNumber
        ))
        try withTemporaryShortcut(action: .moveWorkspaceUp, shortcut: moveWorkspace) {
#if DEBUG
            #expect(!appDelegate.debugHandleCustomShortcut(event: moveWorkspaceEvent))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
        #expect(manager.tabs.map(\.id) == originalWorkspaceOrder)
        #expect(manager.selectedWorkspace?.id == secondWorkspace.id)

        let moveSurface = StoredShortcut(key: "h", command: true, shift: true, option: true, control: true)
        let moveSurfaceEvent = try #require(makeKeyDownEvent(
            key: "h",
            modifiers: [.command, .shift, .option, .control],
            keyCode: 4,
            windowNumber: auxiliaryWindow.windowNumber
        ))
        try withTemporaryShortcut(action: .moveSurfaceLeft, shortcut: moveSurface) {
#if DEBUG
            #expect(!appDelegate.debugHandleCustomShortcut(event: moveSurfaceEvent))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
        #expect(secondWorkspace.bonsplitController.tabs(inPane: paneId).map(\.id) == originalSurfaceOrder)
        #expect(secondWorkspace.focusedPanelId == secondPanel.id)
        #expect(firstWorkspace.id != secondWorkspace.id)
        #expect(firstPanelId != secondPanel.id)
    }
}
