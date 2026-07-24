import AppKit
import Bonsplit
import CmuxFoundation
import CmuxTerminalCore
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

            var attachedPresentationView: NSView?
            if browserPanel.webView.cmuxBrowserViewportAttachmentSuperview == nil,
               let contentView = window.contentView {
                let presentationView = browserPanel.webView.cmuxBrowserViewportPresentationView
                contentView.addSubview(presentationView)
                browserPanel.webView.cmuxApplyBrowserViewportLayout(in: contentView.bounds)
                attachedPresentationView = presentationView
            }
            defer {
                attachedPresentationView?.removeFromSuperview()
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

        guard let event = makeKeyDownEvent(key: "=", modifiers: [.command, .control, .shift], keyCode: 24, windowNumber: window.windowNumber) else {
            XCTFail("Failed to construct Cmd+Ctrl+Shift+= event")
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

    func testConfiguredWorkspaceTerminalFontSizeShortcutAdjustsEverySplit() {
        withTemporaryShortcut(action: .decreaseWorkspaceTerminalFontSize) {
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
                  let firstPanel = workspace.terminalPanel(for: firstPanelId),
                  let secondPanel = workspace.newTerminalSplit(
                    from: firstPanelId,
                    orientation: .horizontal
                  ),
                  let event = makeKeyDownEvent(
                    key: "-",
                    modifiers: [.command, .control],
                    keyCode: 27,
                    windowNumber: window.windowNumber
                  ) else {
                XCTFail("Expected two terminal splits and Cmd+Ctrl+- event")
                return
            }

            let windowDock = appDelegate.windowDock(forWindowId: windowId)
            let dockPanel = TerminalPanel(
                workspaceId: windowDock.workspaceId,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            windowDock.panels[dockPanel.id] = dockPanel

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            let configuredRuntimePoints = Float32(
                GhosttyConfig.load(
                    globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
                ).fontSize
            )
            let beforeLineages = [
                firstPanel.surface.fontSizeLineageSnapshot(),
                secondPanel.surface.fontSizeLineageSnapshot(),
                dockPanel.surface.fontSizeLineageSnapshot(),
            ]

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
            return
#endif

            let surfaces = [firstPanel.surface, secondPanel.surface, dockPanel.surface]
            for (surface, beforeLineage) in zip(surfaces, beforeLineages) {
                guard let afterLineage = surface.fontSizeLineageSnapshot() else {
                    XCTFail("Expected adjusted font-size lineage")
                    continue
                }
                let beforeRuntimePoints = beforeLineage.map {
                    CmuxSurfaceConfigTemplate.runtimeFontSize(
                        fromBasePoints: $0.basePoints,
                        percent: GlobalFontMagnification.storedPercent
                    )
                } ?? configuredRuntimePoints
                let expectedRuntimePoints = TerminalFontSizePolicy().clampedRuntimePoints(
                    beforeRuntimePoints - 1
                )
                let afterRuntimePoints = CmuxSurfaceConfigTemplate.runtimeFontSize(
                    fromBasePoints: afterLineage.basePoints,
                    percent: GlobalFontMagnification.storedPercent
                )
                XCTAssertEqual(afterRuntimePoints, expectedRuntimePoints, accuracy: 0.001)
                XCTAssertTrue(afterLineage.isExplicitOverride)
            }

            guard let sourceDockLineage = dockPanel.surface.fontSizeLineageSnapshot(),
                  let dockPane = windowDock.bonsplitController.allPaneIds.first,
                  let inheritedDockPanelId = windowDock.newSurface(
                    kind: .terminal,
                    inPane: dockPane,
                    focus: false
                  ),
                  let inheritedDockPanel = windowDock.panels[inheritedDockPanelId] as? TerminalPanel else {
                XCTFail("Expected a new Dock terminal after workspace font-size adjustment")
                return
            }
            XCTAssertEqual(
                inheritedDockPanel.surface.fontSizeLineageSnapshot(),
                sourceDockLineage
            )
        }
    }

    func testExplicitWorkspaceFontSizeBindingWinsOverAnotherImplicitFontSizeDefault() {
        withIsolatedShortcutFileStore {
            withDefaultShortcutFallback(action: .increaseWorkspaceTerminalFontSize) {
                withTemporaryShortcut(
                    action: .decreaseWorkspaceTerminalFontSize,
                    shortcut: StoredShortcut(
                        key: "=",
                        command: true,
                        shift: false,
                        option: false,
                        control: true
                    )
                ) {
                    guard let appDelegate = AppDelegate.shared else {
                        XCTFail("Expected AppDelegate.shared")
                        return
                    }

                    let windowId = appDelegate.createMainWindow()
                    defer { closeWindow(withId: windowId) }

                    guard let window = window(withId: windowId),
                          let manager = appDelegate.tabManagerFor(windowId: windowId),
                          let workspace = manager.selectedWorkspace,
                          let panelId = workspace.focusedPanelId,
                          let panel = workspace.terminalPanel(for: panelId),
                          let event = makeKeyDownEvent(
                            key: "=",
                            modifiers: [.command, .control],
                            keyCode: 24,
                            windowNumber: window.windowNumber
                          ) else {
                        XCTFail("Expected a terminal and Cmd+Ctrl+= event")
                        return
                    }

                    window.makeKeyAndOrderFront(nil)
                    window.displayIfNeeded()
                    let configuredRuntimePoints = Float32(
                        GhosttyConfig.load(
                            globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
                        ).fontSize
                    )
                    let beforeRuntimePoints = panel.surface.fontSizeLineageSnapshot().map {
                        CmuxSurfaceConfigTemplate.runtimeFontSize(
                            fromBasePoints: $0.basePoints,
                            percent: GlobalFontMagnification.storedPercent
                        )
                    } ?? configuredRuntimePoints

#if DEBUG
                    XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
                    XCTFail("debugHandleCustomShortcut is only available in DEBUG")
                    return
#endif

                    guard let afterLineage = panel.surface.fontSizeLineageSnapshot() else {
                        XCTFail("Expected adjusted font-size lineage")
                        return
                    }
                    let afterRuntimePoints = CmuxSurfaceConfigTemplate.runtimeFontSize(
                        fromBasePoints: afterLineage.basePoints,
                        percent: GlobalFontMagnification.storedPercent
                    )
                    XCTAssertEqual(
                        afterRuntimePoints,
                        TerminalFontSizePolicy().clampedRuntimePoints(beforeRuntimePoints - 1),
                        accuracy: 0.001
                    )
                    XCTAssertTrue(afterLineage.isExplicitOverride)
                }
            }
        }
    }

    func testConfiguredWorkspaceTerminalFontSizeResetRestoresEverySplit() {
        withTemporaryShortcut(action: .resetWorkspaceTerminalFontSize) {
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
                  let firstPanel = workspace.terminalPanel(for: firstPanelId),
                  let secondPanel = workspace.newTerminalSplit(
                    from: firstPanelId,
                    orientation: .horizontal
                  ),
                  let event = makeKeyDownEvent(
                    key: "0",
                    modifiers: [.command, .control],
                    keyCode: 29,
                    windowNumber: window.windowNumber
                  ) else {
                XCTFail("Expected two terminal splits and Cmd+Ctrl+0 event")
                return
            }

            let windowDock = appDelegate.windowDock(forWindowId: windowId)
            let dockPanel = TerminalPanel(
                workspaceId: windowDock.workspaceId,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            windowDock.panels[dockPanel.id] = dockPanel

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            XCTAssertEqual(
                workspace.adjustTerminalFontSizes(
                    byRuntimePoints: -3,
                    additionalTerminalPanels: [dockPanel]
                ),
                3
            )
            guard let inheritedWhileZoomedPanel = workspace.newTerminalSplit(
                from: firstPanelId,
                orientation: .vertical
            ) else {
                XCTFail("Expected a terminal created after workspace zoom")
                return
            }
            let surfaces = [
                firstPanel.surface,
                secondPanel.surface,
                inheritedWhileZoomedPanel.surface,
                dockPanel.surface,
            ]
            for surface in surfaces {
                XCTAssertTrue(
                    surface.fontSizeLineageSnapshot()?.isExplicitOverride ?? false,
                    "Expected every terminal to own the shrunken size before reset"
                )
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
            return
#endif

            let configuredRuntimePoints = Float32(
                GhosttyConfig.load(
                    globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
                ).fontSize
            )
            for surface in surfaces {
                guard let resetLineage = surface.fontSizeLineageSnapshot() else {
                    XCTFail("Expected reset font-size lineage")
                    continue
                }
                let resetRuntimePoints = CmuxSurfaceConfigTemplate.runtimeFontSize(
                    fromBasePoints: resetLineage.basePoints,
                    percent: GlobalFontMagnification.storedPercent
                )
                XCTAssertEqual(resetRuntimePoints, configuredRuntimePoints, accuracy: 0.001)
                XCTAssertFalse(resetLineage.isExplicitOverride)
                XCTAssertNil(surface.sessionFontSizeOverrideBasePoints())
            }
        }
    }

    func testPersistedLegacyEqualizeShortcutWinsOverNewFontSizeDefault() {
        withIsolatedShortcutFileStore {
            withDefaultShortcutFallback(action: .increaseWorkspaceTerminalFontSize) {
                withTemporaryShortcut(
                    action: .equalizeSplits,
                    shortcut: StoredShortcut(
                        key: "=",
                        command: true,
                        shift: false,
                        option: false,
                        control: true
                    )
                ) {
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
                          let firstPanel = workspace.terminalPanel(for: firstPanelId),
                          let secondPanel = workspace.newTerminalSplit(
                            from: firstPanelId,
                            orientation: .horizontal
                          ),
                          let split = shortcutRoutingSplitNodes(
                            in: workspace.bonsplitController.treeSnapshot()
                          ).first,
                          let splitId = UUID(uuidString: split.id),
                          let event = makeKeyDownEvent(
                            key: "=",
                            modifiers: [.command, .control],
                            keyCode: 24,
                            windowNumber: window.windowNumber
                          ) else {
                        XCTFail("Expected a split and legacy Cmd+Ctrl+= event")
                        return
                    }

                    XCTAssertNil(firstPanel.surface.fontSizeLineageSnapshot())
                    XCTAssertNil(secondPanel.surface.fontSizeLineageSnapshot())
                    XCTAssertTrue(
                        workspace.bonsplitController.setDividerPosition(0.2, forSplit: splitId)
                    )

                    window.makeKeyAndOrderFront(nil)
#if DEBUG
                    XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
                    XCTFail("debugHandleCustomShortcut is only available in DEBUG")
                    return
#endif

                    guard let updatedSplit = shortcutRoutingSplitNodes(
                        in: workspace.bonsplitController.treeSnapshot()
                    ).first(where: { $0.id == split.id }) else {
                        XCTFail("Expected split to remain present")
                        return
                    }
                    XCTAssertEqual(updatedSplit.dividerPosition, 0.5, accuracy: 0.000_1)
                    XCTAssertFalse(
                        firstPanel.surface.fontSizeLineageSnapshot()?.isExplicitOverride ?? false
                    )
                    XCTAssertFalse(
                        secondPanel.surface.fontSizeLineageSnapshot()?.isExplicitOverride ?? false
                    )
                }
            }
        }
    }

    func testPersistedSplitShortcutWinsOverNewFontSizeDefaults() {
        withIsolatedShortcutFileStore {
            let cases: [
                (
                    action: KeyboardShortcutSettings.Action,
                    key: String,
                    keyCode: UInt16
                )
            ] = [
                (.decreaseWorkspaceTerminalFontSize, "-", 27),
                (.resetWorkspaceTerminalFontSize, "0", 29),
            ]

            for testCase in cases {
                withDefaultShortcutFallback(action: testCase.action) {
                    withTemporaryShortcut(
                        action: .splitRight,
                        shortcut: StoredShortcut(
                            key: testCase.key,
                            command: true,
                            shift: false,
                            option: false,
                            control: true
                        )
                    ) {
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
                              let firstPanel = workspace.terminalPanel(for: firstPanelId),
                              let event = makeKeyDownEvent(
                                key: testCase.key,
                                modifiers: [.command, .control],
                                keyCode: testCase.keyCode,
                                windowNumber: window.windowNumber
                              ) else {
                            XCTFail("Expected a terminal and workspace font-size event")
                            return
                        }
                        let panelCountBefore = workspace.panels.count

                        window.makeKeyAndOrderFront(nil)
#if DEBUG
                        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
                        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
                        return
#endif

                        XCTAssertEqual(workspace.panels.count, panelCountBefore + 1)
                        XCTAssertEqual(
                            shortcutRoutingSplitNodes(
                                in: workspace.bonsplitController.treeSnapshot()
                            ).count,
                            1
                        )
                        XCTAssertFalse(
                            firstPanel.surface.fontSizeLineageSnapshot()?.isExplicitOverride ?? false
                        )
                    }
                }
            }
        }
    }

    func testPersistedSplitShortcutWinsOverNewEqualizeDefault() {
        withIsolatedShortcutFileStore {
            withDefaultShortcutFallback(action: .equalizeSplits) {
                withTemporaryShortcut(
                    action: .splitRight,
                    shortcut: StoredShortcut(
                        key: "=",
                        command: true,
                        shift: true,
                        option: false,
                        control: true
                    )
                ) {
                    guard let appDelegate = AppDelegate.shared else {
                        XCTFail("Expected AppDelegate.shared")
                        return
                    }

                    let windowId = appDelegate.createMainWindow()
                    defer { closeWindow(withId: windowId) }

                    guard let window = window(withId: windowId),
                          let manager = appDelegate.tabManagerFor(windowId: windowId),
                          let workspace = manager.selectedWorkspace,
                          let event = makeKeyDownEvent(
                            key: "=",
                            modifiers: [.command, .control, .shift],
                            keyCode: 24,
                            windowNumber: window.windowNumber
                          ) else {
                        XCTFail("Expected a terminal and Cmd+Ctrl+Shift+= event")
                        return
                    }
                    let panelCountBefore = workspace.panels.count

                    window.makeKeyAndOrderFront(nil)
#if DEBUG
                    XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
                    XCTFail("debugHandleCustomShortcut is only available in DEBUG")
                    return
#endif

                    XCTAssertEqual(workspace.panels.count, panelCountBefore + 1)
                    XCTAssertEqual(
                        shortcutRoutingSplitNodes(
                            in: workspace.bonsplitController.treeSnapshot()
                        ).count,
                        1
                    )
                }
            }
        }
    }

    func testWorkspaceFontSizeDefaultsAreNotSuppressedAfterRebinding() {
        withIsolatedShortcutFileStore {
            let cases: [
                (
                    action: KeyboardShortcutSettings.Action,
                    key: String,
                    keyCode: UInt16
                )
            ] = [
                (.increaseWorkspaceTerminalFontSize, "=", 24),
                (.decreaseWorkspaceTerminalFontSize, "-", 27),
                (.resetWorkspaceTerminalFontSize, "0", 29),
            ]

            for testCase in cases {
                guard let event = makeKeyDownEvent(
                    key: testCase.key,
                    modifiers: [.command, .control],
                    keyCode: testCase.keyCode,
                    windowNumber: 0
                ) else {
                    XCTFail("Expected workspace font-size shortcut event")
                    continue
                }
                withTemporaryShortcut(action: testCase.action, shortcut: .unbound) {
                    XCTAssertFalse(
                        AppDelegate.shared?.shouldSuppressStaleCmuxMenuShortcut(event: event) ?? true,
                        "\(testCase.action.rawValue) is routed without an NSMenu item"
                    )
                }
            }
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

    private func withDefaultShortcutFallback(
        action: KeyboardShortcutSettings.Action,
        _ body: () -> Void
    ) {
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: action.defaultsKey)
        defaults.removeObject(forKey: action.defaultsKey)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: action.defaultsKey)
            } else {
                defaults.removeObject(forKey: action.defaultsKey)
            }
        }
        body()
    }

    private func withIsolatedShortcutFileStore(_ body: () -> Void) {
        let originalStore = KeyboardShortcutSettings.settingsFileStore
        let settingsFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-font-zoom-\(UUID().uuidString).json")
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalStore
            try? FileManager.default.removeItem(at: settingsFileURL)
        }
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
