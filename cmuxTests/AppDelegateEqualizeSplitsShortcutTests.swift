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
              workspace.newTerminalSplit(from: rightPanel.id, orientation: .vertical) != nil else {
            XCTFail("Expected nested split setup")
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
        for split in equalizedSplits {
            XCTAssertEqual(split.dividerPosition, 0.5, accuracy: 0.000_1)
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

    private func shortcutRoutingSplitNodes(in node: ExternalTreeNode) -> [ExternalSplitNode] {
        switch node {
        case .pane:
            return []
        case .split(let split):
            return [split] + shortcutRoutingSplitNodes(in: split.first) + shortcutRoutingSplitNodes(in: split.second)
        }
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
