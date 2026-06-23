import AppKit
import Bonsplit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppDelegateEqualizeSplitsShortcutTests: XCTestCase {
    func testCmdShiftReturnFocusedBrowserTogglesSplitZoom() {
        withTemporaryShortcut(action: .toggleSplitZoom) {
            guard let appDelegate = AppDelegate.shared else {
                XCTFail("Expected AppDelegate.shared")
                return
            }

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            guard let window = window(withId: windowId),
                  let manager = appDelegate.tabManagerFor(windowId: windowId),
                  let workspace = manager.selectedWorkspace,
                  let browserPanelId = manager.openBrowser(inWorkspace: workspace.id, preferSplitRight: true),
                  let browserPanel = workspace.browserPanel(for: browserPanelId),
                  let event = makeKeyDownEvent(key: "\r", modifiers: [.command, .shift], keyCode: 36, windowNumber: window.windowNumber) else {
                XCTFail("Expected focused browser panel and Cmd+Shift+Return event")
                return
            }

            workspace.focusPanel(browserPanel.id)
            XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)
            XCTAssertFalse(workspace.bonsplitController.isSplitZoomed)

            var didAttachForTest = false
            if browserPanel.webView.superview == nil {
                browserPanel.webView.frame = window.contentView?.bounds ?? .zero
                window.contentView?.addSubview(browserPanel.webView)
                didAttachForTest = true
            }
            defer {
                if didAttachForTest { browserPanel.webView.removeFromSuperview() }
            }

            window.makeKeyAndOrderFront(nil)
            XCTAssertTrue(window.makeFirstResponder(browserPanel.webView))
            XCTAssertTrue(KeyboardShortcutSettings.shortcut(for: .toggleSplitZoom).matches(event: event))

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleShortcutMonitorEvent(event: event))
            XCTAssertTrue(workspace.bonsplitController.isSplitZoomed)
            XCTAssertTrue(workspace.clearSplitZoom())
#else
            XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG")
#endif

            XCTAssertTrue(browserPanel.webView.performKeyEquivalent(with: event))
            XCTAssertTrue(workspace.bonsplitController.isSplitZoomed)
        }
    }

    func testCmdShiftReturnInCanvasModeDoesNotToggleBonsplitSplitZoom() {
        withTemporaryShortcut(action: .toggleSplitZoom) {
            guard let appDelegate = AppDelegate.shared else {
                XCTFail("Expected AppDelegate.shared")
                return
            }

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            guard let window = window(withId: windowId),
                  let manager = appDelegate.tabManagerFor(windowId: windowId),
                  let workspace = manager.selectedWorkspace,
                  let leftPanelId = workspace.focusedPanelId,
                  workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) != nil,
                  let event = makeKeyDownEvent(key: "\r", modifiers: [.command, .shift], keyCode: 36, windowNumber: window.windowNumber) else {
                XCTFail("Expected split workspace and Cmd+Shift+Return event")
                return
            }

            workspace.setLayoutMode(.canvas)
            XCTAssertEqual(workspace.layoutMode, .canvas)
            XCTAssertFalse(workspace.bonsplitController.isSplitZoomed)
            XCTAssertTrue(KeyboardShortcutSettings.shortcut(for: .toggleSplitZoom).matches(event: event))

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
            XCTAssertFalse(
                workspace.bonsplitController.isSplitZoomed,
                "In canvas mode, the split-zoom shortcut should drive canvas overview instead of Bonsplit zoom"
            )
        }
    }

    func testConfiguredEqualizeSplitsShortcutBalancesWorkspaceDividers() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              workspace.newTerminalSplit(from: rightPanel.id, orientation: .horizontal) != nil else {
            XCTFail("Expected asymmetric horizontal split setup")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let seededSplits = shortcutRoutingSplitNodes(in: workspace.bonsplitController.treeSnapshot())
        XCTAssertGreaterThanOrEqual(seededSplits.count, 2, "Expected nested splits")

        var seededTargetsBySplitId: [String: Double] = [:]
        for (index, split) in seededSplits.enumerated() {
            guard let splitId = UUID(uuidString: split.id) else {
                XCTFail("Expected split ID to be a UUID")
                return
            }
            let targetPosition: CGFloat = index.isMultiple(of: 2) ? 0.2 : 0.8
            seededTargetsBySplitId[split.id] = Double(targetPosition)
            XCTAssertTrue(workspace.bonsplitController.setDividerPosition(targetPosition, forSplit: splitId))
        }

        let postSeedSplits = shortcutRoutingSplitNodes(in: workspace.bonsplitController.treeSnapshot())
        XCTAssertEqual(postSeedSplits.count, seededSplits.count)
        for split in postSeedSplits {
            guard let targetPosition = seededTargetsBySplitId[split.id] else {
                XCTFail("Expected seeded split to remain present")
                return
            }
            XCTAssertEqual(split.dividerPosition, targetPosition, accuracy: 0.000_1)
            XCTAssertNotEqual(split.dividerPosition, 0.5, accuracy: 0.000_1)
        }

        workspace.splitTabBar(workspace.bonsplitController, didChangeGeometry: workspace.bonsplitController.layoutSnapshot())
        guard let seededLayoutSnapshot = workspace.tmuxLayoutSnapshot else {
            XCTFail("Expected cached layout snapshot after seeding split geometry")
            return
        }
        let expectedEqualizedPositions = shortcutRoutingExpectedEqualizedDividerPositions(
            in: workspace.bonsplitController.treeSnapshot()
        )

        guard let event = makeKeyDownEvent(key: "=", modifiers: [.command, .control], keyCode: 24, windowNumber: window.windowNumber) else {
            XCTFail("Failed to construct Cmd+Ctrl+= event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
        return
#endif
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))

        let equalizedSplits = shortcutRoutingSplitNodes(in: workspace.bonsplitController.treeSnapshot())
        XCTAssertEqual(equalizedSplits.count, seededSplits.count)
        let equalizedLeafCount = shortcutRoutingAssertProportionalEqualizedTree(
            workspace.bonsplitController.treeSnapshot()
        )
        XCTAssertEqual(equalizedLeafCount, 3)
        for split in equalizedSplits {
            guard let expectedPosition = expectedEqualizedPositions[split.id] else {
                XCTFail("Expected equalized split ID to remain present")
                continue
            }
            XCTAssertEqual(split.dividerPosition, expectedPosition, accuracy: 0.000_1)
        }

        let liveEqualizedLayout = workspace.bonsplitController.layoutSnapshot()
        guard let cachedEqualizedLayout = workspace.tmuxLayoutSnapshot else {
            XCTFail("Expected cached layout snapshot after equalizing split geometry")
            return
        }
        XCTAssertNotEqual(
            shortcutRoutingPaneFramesById(in: seededLayoutSnapshot),
            shortcutRoutingPaneFramesById(in: liveEqualizedLayout)
        )
        shortcutRoutingAssertPaneFramesMatch(cachedEqualizedLayout, liveEqualizedLayout)
    }

    func testCmdDInCanvasCreatesFloatingCanvasPaneWithoutBonsplitSplit() {
        withTemporaryShortcut(action: .splitRight) {
            guard let appDelegate = AppDelegate.shared else {
                XCTFail("Expected AppDelegate.shared")
                return
            }

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            guard let window = window(withId: windowId),
                  let manager = appDelegate.tabManagerFor(windowId: windowId),
                  let workspace = manager.selectedWorkspace,
                  let focusedPanelId = workspace.focusedPanelId,
                  let event = makeKeyDownEvent(key: "d", modifiers: [.command], keyCode: 2, windowNumber: window.windowNumber) else {
                XCTFail("Expected focused workspace and Cmd+D event")
                return
            }

            window.makeKeyAndOrderFront(nil)
            workspace.setLayoutMode(.canvas)
            let originalBonsplitPaneCount = workspace.bonsplitController.allPaneIds.count
            let originalPanelIds = Set(workspace.panels.keys)
            let originalFrame = workspace.canvasModel.frame(of: focusedPanelId)

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
            return
#endif

            let newPanelIds = Set(workspace.panels.keys).subtracting(originalPanelIds)
            XCTAssertEqual(newPanelIds.count, 1)
            XCTAssertEqual(
                workspace.bonsplitController.allPaneIds.count,
                originalBonsplitPaneCount,
                "Canvas split shortcuts should create visible canvas panes without splitting the hidden Bonsplit tree"
            )
            XCTAssertEqual(workspace.canvasModel.persistablePanes.count, 2)

            if let newPanelId = newPanelIds.first,
               let originalFrame,
               let newFrame = workspace.canvasModel.frame(of: newPanelId) {
                XCTAssertGreaterThanOrEqual(newFrame.minX, originalFrame.maxX)
                XCTAssertEqual(workspace.focusedPanelId, newPanelId)
            } else {
                XCTFail("Expected the new canvas pane to have a frame")
            }
        }
    }

    func testCmdShiftDInCanvasPlacesFloatingCanvasPaneBelowFocusedPane() {
        withTemporaryShortcut(action: .splitDown) {
            guard let appDelegate = AppDelegate.shared else {
                XCTFail("Expected AppDelegate.shared")
                return
            }

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            guard let window = window(withId: windowId),
                  let manager = appDelegate.tabManagerFor(windowId: windowId),
                  let workspace = manager.selectedWorkspace,
                  let focusedPanelId = workspace.focusedPanelId,
                  let event = makeKeyDownEvent(key: "d", modifiers: [.command, .shift], keyCode: 2, windowNumber: window.windowNumber) else {
                XCTFail("Expected focused workspace and Cmd+Shift+D event")
                return
            }

            window.makeKeyAndOrderFront(nil)
            workspace.setLayoutMode(.canvas)
            let originalPanelIds = Set(workspace.panels.keys)
            let originalFrame = workspace.canvasModel.frame(of: focusedPanelId)

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
            return
#endif

            let newPanelIds = Set(workspace.panels.keys).subtracting(originalPanelIds)
            XCTAssertEqual(newPanelIds.count, 1)
            if let newPanelId = newPanelIds.first,
               let originalFrame,
               let newFrame = workspace.canvasModel.frame(of: newPanelId) {
                XCTAssertGreaterThanOrEqual(newFrame.minY, originalFrame.maxY)
            } else {
                XCTFail("Expected the new canvas pane to have a frame")
            }
        }
    }

    func testNumberedSurfaceShortcutSelectsCanvasPaneTab() {
        withTemporaryShortcut(action: .selectSurfaceByNumber) {
            guard let appDelegate = AppDelegate.shared else {
                XCTFail("Expected AppDelegate.shared")
                return
            }

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            guard let window = window(withId: windowId),
                  let manager = appDelegate.tabManagerFor(windowId: windowId),
                  let workspace = manager.selectedWorkspace,
                  let firstPanelId = workspace.focusedPanelId,
                  let event = makeKeyDownEvent(key: "2", modifiers: [.control], keyCode: 19, windowNumber: window.windowNumber) else {
                XCTFail("Expected two canvas tabs and Ctrl+2 event")
                return
            }

            window.makeKeyAndOrderFront(nil)
            workspace.setLayoutMode(.canvas)
            guard let secondPanel = workspace.newTerminalSurfaceInFocusedPane(focus: true) else {
                XCTFail("Expected second canvas tab")
                return
            }
            workspace.focusPanel(firstPanelId)
            XCTAssertEqual(workspace.focusedPanelId, firstPanelId)

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
            return
#endif

            XCTAssertEqual(workspace.focusedPanelId, secondPanel.id)
        }
    }

    func testEqualizeSplitsShortcutInCanvasEqualizesCanvasPaneSizesOnly() {
        withTemporaryShortcut(action: .equalizeSplits) {
            guard let appDelegate = AppDelegate.shared else {
                XCTFail("Expected AppDelegate.shared")
                return
            }

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            guard let window = window(withId: windowId),
                  let manager = appDelegate.tabManagerFor(windowId: windowId),
                  let workspace = manager.selectedWorkspace,
                  let firstPanelId = workspace.focusedPanelId,
                  let event = makeKeyDownEvent(key: "=", modifiers: [.command, .control], keyCode: 24, windowNumber: window.windowNumber) else {
                XCTFail("Expected focused workspace and Cmd+Ctrl+= event")
                return
            }

            window.makeKeyAndOrderFront(nil)
            workspace.setLayoutMode(.canvas)
            guard let secondPanelId = workspace.openNewCanvasPane(type: .terminal, focus: true) else {
                XCTFail("Expected second canvas pane")
                return
            }
            let originalBonsplitPaneCount = workspace.bonsplitController.allPaneIds.count
            workspace.canvasModel.setFrame(CGRect(x: 0, y: 0, width: 640, height: 420), for: firstPanelId)
            workspace.canvasModel.setFrame(CGRect(x: 720, y: 0, width: 320, height: 260), for: secondPanelId)

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
            return
#endif

            guard let firstFrame = workspace.canvasModel.frame(of: firstPanelId),
                  let secondFrame = workspace.canvasModel.frame(of: secondPanelId) else {
                XCTFail("Expected canvas frames after equalize")
                return
            }
            XCTAssertEqual(firstFrame.width, secondFrame.width, accuracy: 0.000_1)
            XCTAssertEqual(firstFrame.height, secondFrame.height, accuracy: 0.000_1)
            XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, originalBonsplitPaneCount)
        }
    }

    private func shortcutRoutingSplitNodes(in node: ExternalTreeNode) -> [ExternalSplitNode] {
        switch node {
        case .pane:
            return []
        case .split(let split):
            return [split] + shortcutRoutingSplitNodes(in: split.first) + shortcutRoutingSplitNodes(in: split.second)
        }
    }

    @discardableResult
    private func shortcutRoutingAssertProportionalEqualizedTree(
        _ node: ExternalTreeNode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        switch node {
        case .pane:
            return 1
        case .split(let split):
            let firstLeafCount = shortcutRoutingAssertProportionalEqualizedTree(split.first, file: file, line: line)
            let secondLeafCount = shortcutRoutingAssertProportionalEqualizedTree(split.second, file: file, line: line)
            let totalLeafCount = firstLeafCount + secondLeafCount
            XCTAssertEqual(
                split.dividerPosition,
                Double(firstLeafCount) / Double(totalLeafCount),
                accuracy: 0.000_1,
                file: file,
                line: line
            )
            return totalLeafCount
        }
    }

    private func shortcutRoutingExpectedEqualizedDividerPositions(in node: ExternalTreeNode) -> [String: Double] {
        var positionsBySplitId: [String: Double] = [:]

        @discardableResult
        func collectLeafCount(_ node: ExternalTreeNode) -> Int {
            switch node {
            case .pane:
                return 1
            case .split(let split):
                let firstLeafCount = collectLeafCount(split.first)
                let secondLeafCount = collectLeafCount(split.second)
                let totalLeafCount = firstLeafCount + secondLeafCount
                positionsBySplitId[split.id] = Double(firstLeafCount) / Double(totalLeafCount)
                return totalLeafCount
            }
        }

        collectLeafCount(node)
        return positionsBySplitId
    }

    private func shortcutRoutingPaneFramesById(in snapshot: LayoutSnapshot) -> [String: PixelRect] {
        Dictionary(uniqueKeysWithValues: snapshot.panes.map { ($0.paneId, $0.frame) })
    }

    private func shortcutRoutingAssertPaneFramesMatch(
        _ lhs: LayoutSnapshot,
        _ rhs: LayoutSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let lhsFrames = shortcutRoutingPaneFramesById(in: lhs)
        let rhsFrames = shortcutRoutingPaneFramesById(in: rhs)
        XCTAssertEqual(Set(lhsFrames.keys), Set(rhsFrames.keys), file: file, line: line)

        for paneId in lhsFrames.keys {
            guard let lhsFrame = lhsFrames[paneId], let rhsFrame = rhsFrames[paneId] else {
                XCTFail("Expected pane \(paneId) in both layout snapshots", file: file, line: line)
                continue
            }
            XCTAssertEqual(lhsFrame.x, rhsFrame.x, accuracy: 0.000_1, file: file, line: line)
            XCTAssertEqual(lhsFrame.y, rhsFrame.y, accuracy: 0.000_1, file: file, line: line)
            XCTAssertEqual(lhsFrame.width, rhsFrame.width, accuracy: 0.000_1, file: file, line: line)
            XCTAssertEqual(lhsFrame.height, rhsFrame.height, accuracy: 0.000_1, file: file, line: line)
        }
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
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
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func withTemporaryShortcut(
        action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut? = nil,
        _ body: () -> Void
    ) {
        let hadPersistedShortcut = UserDefaults.standard.object(forKey: action.defaultsKey) != nil
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            if hadPersistedShortcut {
                KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
        }
        KeyboardShortcutSettings.setShortcut(shortcut ?? action.defaultShortcut, for: action)
        body()
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        window.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
