import AppKit
import Bonsplit
import CmuxFoundation
import CmuxTerminalCore
import XCTest
@testable import CmuxTerminal

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

    func testWorkspaceTerminalFontSizeShortcutSeedsDockCreatedAfterShortcut() {
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
                  let event = makeKeyDownEvent(
                    key: "-",
                    modifiers: [.command, .control],
                    keyCode: 27,
                    windowNumber: window.windowNumber
                  ) else {
                XCTFail("Expected a workspace and Cmd+Ctrl+- event")
                return
            }

            XCTAssertNil(appDelegate.existingWindowDock(forWindowId: windowId))
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
            return
#endif

            XCTAssertNil(
                appDelegate.existingWindowDock(forWindowId: windowId),
                "Font zoom should not eagerly create a hidden Dock"
            )
            guard let expectedLineage =
                    workspace.lastRememberedTerminalFontSizeLineageForConfigInheritance(),
                  let dockPane = appDelegate.windowDock(forWindowId: windowId)
                    .bonsplitController.allPaneIds.first,
                  let inheritedDockPanelId = appDelegate.windowDock(forWindowId: windowId)
                    .newSurface(kind: .terminal, inPane: dockPane, focus: false),
                  let inheritedDockPanel = appDelegate.windowDock(forWindowId: windowId)
                    .panels[inheritedDockPanelId] as? TerminalPanel else {
                XCTFail("Expected a new Dock terminal after workspace font-size adjustment")
                return
            }

            XCTAssertEqual(
                inheritedDockPanel.surface.fontSizeLineageSnapshot(),
                expectedLineage
            )
        }
    }

    func testWorkspaceTerminalFontSizeRepeatEventsCoalesceUntilFlush() {
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
                  let panelId = workspace.focusedPanelId,
                  let panel = workspace.terminalPanel(for: panelId),
                  let repeatedEvent = makeKeyDownEvent(
                    key: "-",
                    modifiers: [.command, .control],
                    keyCode: 27,
                    windowNumber: window.windowNumber,
                    isARepeat: true
                  ) else {
                XCTFail("Expected a terminal and repeated Cmd+Ctrl+- event")
                return
            }

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            let configuredRuntimePoints = Float32(
                GhosttyConfig.load(
                    globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
                ).fontSize
            )
            let beforeLineage = panel.surface.fontSizeLineageSnapshot()
            let beforeRuntimePoints = beforeLineage.map {
                CmuxSurfaceConfigTemplate.runtimeFontSize(
                    fromBasePoints: $0.basePoints,
                    percent: GlobalFontMagnification.storedPercent
                )
            } ?? configuredRuntimePoints

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEvent))
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEvent))
            XCTAssertEqual(panel.surface.fontSizeLineageSnapshot(), beforeLineage)
            appDelegate.debugFlushPendingWorkspaceTerminalFontSizeChanges()
#else
            XCTFail("Workspace font-size coalescer hooks are only available in DEBUG")
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
                TerminalFontSizePolicy().clampedRuntimePoints(beforeRuntimePoints - 2),
                accuracy: 0.001
            )
        }
    }

    func testWorkspaceTerminalFontSizeRepeatEventsCoalesceAcrossRunLoopTurns() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected a selected workspace terminal")
            return
        }
        panel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )

        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: scheduler.schedule(delay:action:)
        )
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )

        let secondRunLoopTurn = expectation(
            description: "second repeat event on a later run-loop turn"
        )
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                coordinator.enqueue(
                    .relative([-1]),
                    workspaceId: workspace.id,
                    deferFlush: true
                )
                secondRunLoopTurn.fulfill()
            }
        }
        wait(for: [secondRunLoopTurn], timeout: 1)

        XCTAssertEqual(scheduler.delays, [0.05])
        XCTAssertEqual(
            panel.surface.fontSizeLineageSnapshot()?.basePoints,
            20,
            "Separate run-loop turns must share one scheduled repeat batch"
        )
#if DEBUG
        XCTAssertEqual(coordinator.debugPendingRequestCount, 1)
#endif

        scheduler.fire(at: 0)
        XCTAssertEqual(
            panel.surface.fontSizeLineageSnapshot()?.basePoints,
            18
        )
    }

    func testWorkspaceTerminalFontSizeResetRepeatDoesNotQueueFanout() {
        withTemporaryShortcut(action: .resetWorkspaceTerminalFontSize) {
            guard let appDelegate = AppDelegate.shared else {
                XCTFail("Expected AppDelegate.shared")
                return
            }

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            guard let window = window(withId: windowId),
                  let repeatedEvent = makeKeyDownEvent(
                    key: "0",
                    modifiers: [.command, .control],
                    keyCode: 29,
                    windowNumber: window.windowNumber,
                    isARepeat: true
                  ) else {
                XCTFail("Expected repeated Cmd+Ctrl+0 event")
                return
            }

#if DEBUG
            appDelegate.debugFlushPendingWorkspaceTerminalFontSizeChanges()
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEvent))
            XCTAssertEqual(
                appDelegate.debugPendingWorkspaceTerminalFontSizeChangeCount,
                0
            )
#else
            XCTFail("Workspace font-size coalescer hooks are only available in DEBUG")
#endif
        }
    }

    func testWorkspaceTerminalFontSizeRepeatDrainBoundsOneTurn() {
        withTemporaryShortcut(action: .decreaseWorkspaceTerminalFontSize) {
            guard let appDelegate = AppDelegate.shared else {
                XCTFail("Expected AppDelegate.shared")
                return
            }

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            guard let window = window(withId: windowId),
                  let repeatedEvent = makeKeyDownEvent(
                    key: "-",
                    modifiers: [.command, .control],
                    keyCode: 27,
                    windowNumber: window.windowNumber,
                    isARepeat: true
                  ) else {
                XCTFail("Expected repeated Cmd+Ctrl+- event")
                return
            }

            let windowDock = appDelegate.windowDock(forWindowId: windowId)
            let dockPanels = (0..<12).map { _ in
                var configTemplate = CmuxSurfaceConfigTemplate()
                configTemplate.fontSizeLineage = TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
                let panel = TerminalPanel(
                    workspaceId: windowDock.workspaceId,
                    configTemplate: configTemplate,
                    runtimeSpawnPolicy: .pacedSessionRestore
                )
                windowDock.panels[panel.id] = panel
                return panel
            }

#if DEBUG
            appDelegate.debugFlushPendingWorkspaceTerminalFontSizeChanges()
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEvent))
            appDelegate.debugFlushPendingWorkspaceTerminalFontSizeChanges()
#else
            XCTFail("Workspace font-size coalescer hooks are only available in DEBUG")
            return
#endif

            let adjustedCount = dockPanels.count {
                $0.surface.fontSizeLineageSnapshot()?.basePoints == 19
            }
            XCTAssertGreaterThan(adjustedCount, 0)
            XCTAssertLessThanOrEqual(
                adjustedCount,
                8,
                "One event-loop drain must have a fixed panel/action budget"
            )
            XCTAssertLessThan(adjustedCount, dockPanels.count)

            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        }
    }

    func testWorkspaceTerminalFontSizeDrainSeedsLateTerminalsExactlyOnce() {
        withTemporaryShortcut(action: .decreaseWorkspaceTerminalFontSize) {
            guard let appDelegate = AppDelegate.shared else {
                XCTFail("Expected AppDelegate.shared")
                return
            }

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            guard let window = window(withId: windowId),
                  let repeatedEvent = makeKeyDownEvent(
                    key: "-",
                    modifiers: [.command, .control],
                    keyCode: 27,
                    windowNumber: window.windowNumber,
                    isARepeat: true
                  ) else {
                XCTFail("Expected repeated Cmd+Ctrl+- event")
                return
            }

            let windowDock = appDelegate.windowDock(forWindowId: windowId)
            @MainActor
            func dormantPanel(id: UUID, basePoints: Float32 = 20) -> TerminalPanel {
                var configTemplate = CmuxSurfaceConfigTemplate()
                configTemplate.fontSizeLineage = TerminalFontSizeLineage(
                    basePoints: basePoints,
                    isExplicitOverride: true
                )
                let panel = TerminalPanel(
                    id: id,
                    workspaceId: windowDock.workspaceId,
                    configTemplate: configTemplate,
                    runtimeSpawnPolicy: .pacedSessionRestore
                )
                windowDock.panels[panel.id] = panel
                return panel
            }

            let sourcePanels = (1...32).map { suffix in
                dormantPanel(
                    id: UUID(
                        uuidString: String(
                            format: "00000000-0000-4000-8000-%012d",
                            suffix
                        )
                    )!
                )
            }

#if DEBUG
            appDelegate.debugFlushPendingWorkspaceTerminalFontSizeChanges()
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEvent))
            appDelegate.debugFlushPendingWorkspaceTerminalFontSizeChanges()
#else
            XCTFail("Workspace font-size drain hooks are only available in DEBUG")
            return
#endif

            if let lineageProbeCount =
                    windowDock
                        .debugActiveTerminalFontSizeChangeInitialLineageProbeCount {
                XCTAssertLessThanOrEqual(
                    lineageProbeCount,
                    1,
                    "Drain activation must not snapshot every terminal lineage"
                )
            } else {
                XCTFail("Expected an active Dock font-size inheritance context")
            }

            guard let adjustedSource = sourcePanels.first(where: {
                $0.surface.fontSizeLineageSnapshot()?.basePoints == 19
            }) else {
                XCTFail("Expected one source inside the first bounded drain")
                return
            }
            let staleSource = dormantPanel(
                id: UUID(uuidString: "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF")!,
                basePoints: 19
            )
            XCTAssertEqual(
                staleSource.surface.fontSizeLineageSnapshot()?.basePoints,
                19
            )

            guard let dockPane = windowDock.bonsplitController.allPaneIds.first,
                  let adjustedLatePanelId = windowDock.newSurface(
                    kind: .terminal,
                    inPane: dockPane,
                    sourcePanelId: adjustedSource.id,
                    focus: false
                  ),
                  let adjustedLatePanel =
                    windowDock.panels[adjustedLatePanelId] as? TerminalPanel,
                  let staleLatePanelId = windowDock.newSurface(
                    kind: .terminal,
                    inPane: dockPane,
                    sourcePanelId: staleSource.id,
                    focus: false
                  ),
                  let staleLatePanel =
                    windowDock.panels[staleLatePanelId] as? TerminalPanel else {
                XCTFail("Expected late Dock terminals from adjusted and stale sources")
                return
            }

            XCTAssertEqual(
                adjustedLatePanel.surface.fontSizeLineageSnapshot()?.basePoints,
                19
            )
            XCTAssertEqual(
                staleLatePanel.surface.fontSizeLineageSnapshot()?.basePoints,
                18,
                "A late terminal must inherit the pending result for its exact stale source"
            )

#if DEBUG
            appDelegate.debugDrainAllPendingWorkspaceTerminalFontSizeChanges()
#endif

            XCTAssertEqual(
                adjustedLatePanel.surface.fontSizeLineageSnapshot()?.basePoints,
                19,
                "A late terminal inheriting the final lineage must not receive the request twice"
            )
            XCTAssertEqual(
                staleLatePanel.surface.fontSizeLineageSnapshot()?.basePoints,
                18,
                "A late terminal inheriting a stale source must still receive the request once"
            )
        }
    }

    func testWorkspaceTerminalFontSizeDrainSeedsLazyWindowDockOnce() {
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
                  let repeatedEvent = makeKeyDownEvent(
                    key: "-",
                    modifiers: [.command, .control],
                    keyCode: 27,
                    windowNumber: window.windowNumber,
                    isARepeat: true
                  ) else {
                XCTFail("Expected workspace and repeated Cmd+Ctrl+- event")
                return
            }

            var inheritanceSourceConfig = CmuxSurfaceConfigTemplate()
            inheritanceSourceConfig.fontSizeLineage = TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
            let inheritanceSource = TerminalPanel(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000101")!,
                workspaceId: workspace.id,
                configTemplate: inheritanceSourceConfig,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            workspace.panels[inheritanceSource.id] = inheritanceSource
            workspace.rememberTerminalConfigInheritanceSource(
                inheritanceSource
            )
            for suffix in 102...112 {
                var configTemplate = CmuxSurfaceConfigTemplate()
                configTemplate.fontSizeLineage = TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
                let panel = TerminalPanel(
                    id: UUID(
                        uuidString: String(
                            format: "00000000-0000-4000-8000-%012d",
                            suffix
                        )
                    )!,
                    workspaceId: workspace.id,
                    configTemplate: configTemplate,
                    runtimeSpawnPolicy: .pacedSessionRestore
                )
                workspace.panels[panel.id] = panel
            }

#if DEBUG
            appDelegate.debugFlushPendingWorkspaceTerminalFontSizeChanges()
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEvent))
            appDelegate.debugFlushPendingWorkspaceTerminalFontSizeChanges()
#else
            XCTFail("Workspace font-size drain hooks are only available in DEBUG")
            return
#endif

            let windowDock = appDelegate.windowDock(forWindowId: windowId)
            guard let dockPane = windowDock.bonsplitController.allPaneIds.first,
                  let latePanelId = windowDock.newSurface(
                    kind: .terminal,
                    inPane: dockPane,
                    focus: false
                  ),
                  let latePanel =
                    windowDock.panels[latePanelId] as? TerminalPanel else {
                XCTFail("Expected a terminal in the lazily-created window Dock")
                return
            }
            XCTAssertEqual(
                latePanel.surface.fontSizeLineageSnapshot()?.basePoints,
                19,
                "The already-predicted lazy Dock fallback must not be decremented twice"
            )

#if DEBUG
            appDelegate.debugDrainAllPendingWorkspaceTerminalFontSizeChanges()
#endif
            XCTAssertEqual(
                latePanel.surface.fontSizeLineageSnapshot()?.basePoints,
                19
            )
        }
    }

    func testWorkspaceTerminalFontSizeSharedDockPreservesCrossWorkspaceEventOrder() {
        withTemporaryShortcut(action: .increaseWorkspaceTerminalFontSize) {
            withTemporaryShortcut(action: .decreaseWorkspaceTerminalFontSize) {
                guard let appDelegate = AppDelegate.shared else {
                    XCTFail("Expected AppDelegate.shared")
                    return
                }

                let windowId = appDelegate.createMainWindow()
                defer { closeWindow(withId: windowId) }

                guard let window = window(withId: windowId),
                      let manager = appDelegate.tabManagerFor(windowId: windowId),
                      let firstWorkspace = manager.selectedWorkspace,
                      let increaseEvent = makeKeyDownEvent(
                        key: "=",
                        modifiers: [.command, .control],
                        keyCode: 24,
                        windowNumber: window.windowNumber,
                        isARepeat: true
                      ),
                      let decreaseEvent = makeKeyDownEvent(
                        key: "-",
                        modifiers: [.command, .control],
                        keyCode: 27,
                        windowNumber: window.windowNumber,
                        isARepeat: true
                      ) else {
                    XCTFail("Expected two workspace font-size repeat events")
                    return
                }

                let windowDock = appDelegate.windowDock(forWindowId: windowId)
                var maximumConfig = CmuxSurfaceConfigTemplate()
                maximumConfig.fontSizeLineage = TerminalFontSizeLineage(
                    basePoints: TerminalFontSizePolicy.maximumRuntimePoints,
                    isExplicitOverride: true
                )
                let maximumPanel = TerminalPanel(
                    workspaceId: windowDock.workspaceId,
                    configTemplate: maximumConfig,
                    runtimeSpawnPolicy: .pacedSessionRestore
                )
                windowDock.panels[maximumPanel.id] = maximumPanel

                var minimumConfig = CmuxSurfaceConfigTemplate()
                minimumConfig.fontSizeLineage = TerminalFontSizeLineage(
                    basePoints: TerminalFontSizePolicy.minimumRuntimePoints,
                    isExplicitOverride: true
                )
                let minimumPanel = TerminalPanel(
                    workspaceId: windowDock.workspaceId,
                    configTemplate: minimumConfig,
                    runtimeSpawnPolicy: .pacedSessionRestore
                )
                windowDock.panels[minimumPanel.id] = minimumPanel

#if DEBUG
                appDelegate.debugFlushPendingWorkspaceTerminalFontSizeChanges()
                XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: increaseEvent))

                let secondWorkspace = manager.addTab(select: true)
                XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: decreaseEvent))

                manager.selectTab(firstWorkspace)
                XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: increaseEvent))
                appDelegate.debugDrainAllPendingWorkspaceTerminalFontSizeChanges()
#else
                XCTFail("Workspace font-size coalescer hooks are only available in DEBUG")
                return
#endif

                XCTAssertEqual(
                    maximumPanel.surface.fontSizeLineageSnapshot()?.basePoints,
                    TerminalFontSizePolicy.maximumRuntimePoints
                )
                XCTAssertEqual(
                    minimumPanel.surface.fontSizeLineageSnapshot()?.basePoints,
                    TerminalFontSizePolicy.minimumRuntimePoints + 1
                )
            }
        }
    }

    func testWorkspaceTerminalFontSizeDrainBudgetCapsLiveActionsAndPanelVisits() {
        var liveBudget = WorkspaceTerminalFontSizeDrainBudget()
        for _ in 0..<4 {
            XCTAssertTrue(
                liveBudget.reserve(
                    panelHasLiveSurface: true,
                    nativeActionUpperBound: 2
                )
            )
        }
        XCTAssertEqual(
            liveBudget.liveActionUpperBound,
            WorkspaceTerminalFontSizeDrainBudget.maximumLiveActionsPerDrain
        )
        XCTAssertFalse(
            liveBudget.reserve(
                panelHasLiveSurface: true,
                nativeActionUpperBound: 1
            )
        )

        var panelBudget = WorkspaceTerminalFontSizeDrainBudget()
        for _ in 0..<WorkspaceTerminalFontSizeDrainBudget.maximumPanelVisitsPerDrain {
            XCTAssertTrue(
                panelBudget.reserve(
                    panelHasLiveSurface: false,
                    nativeActionUpperBound: 2
                )
            )
        }
        XCTAssertFalse(
            panelBudget.reserve(
                panelHasLiveSurface: false,
                nativeActionUpperBound: 2
            )
        )

        var requestBudget = WorkspaceTerminalFontSizeDrainBudget()
        for _ in 0..<WorkspaceTerminalFontSizeDrainBudget.maximumRequestVisitsPerDrain {
            XCTAssertTrue(requestBudget.reserveRequestVisit())
        }
        XCTAssertFalse(requestBudget.reserveRequestVisit())
    }

    func testPendingWorkspaceTerminalFontSizeChangeBoundsAlternatingStorage() {
        var change = WorkspaceTerminalFontSizeChange.relative([])
        for index in 0..<10_000 {
            change.appendAdjustment(index.isMultiple(of: 2) ? 1 : -1)
        }

        XCTAssertLessThanOrEqual(
            storedFloatCount(in: change),
            3,
            "Coalescing must retain a constant-size clamp transform, not every key event"
        )
    }

    func testPendingWorkspaceTerminalFontSizeChangeBoundsAlternatingWorkspaceStorage() {
        let manager = TabManager()
        guard let firstWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected an initial workspace")
            return
        }
        let secondWorkspace = manager.addTab(select: false)
        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: scheduler.schedule(delay:action:)
        )
        defer { coordinator.cancelAll() }

        for index in 0..<10_000 {
            coordinator.enqueue(
                .relative([index.isMultiple(of: 2) ? 1 : -1]),
                workspaceId: index.isMultiple(of: 2)
                    ? firstWorkspace.id
                    : secondWorkspace.id,
                deferFlush: true
            )
        }

#if DEBUG
        XCTAssertLessThanOrEqual(
            coordinator.debugPendingRequestCount,
            2,
            "Alternating live workspace ids must coalesce by workspace instead of retaining every event"
        )
#else
        XCTFail("Workspace font-size coalescer hooks are only available in DEBUG")
#endif
        XCTAssertEqual(
            scheduler.delays,
            [0.05],
            "One repeat-coalescing timer should cover the entire pending batch"
        )
    }

    func testWorkspaceTerminalFontSizeEnqueueDoesNotProbeDockPanels() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected an initial workspace")
            return
        }
        let windowDock = manager.makeWindowDockStore(windowId: UUID())
        for _ in 0..<32 {
            let panel = TerminalPanel(
                workspaceId: windowDock.workspaceId,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            windowDock.panels[panel.id] = panel
        }
        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: scheduler.schedule(delay:action:)
        )
        coordinator.attachWindowDock(windowDock)
        defer {
            coordinator.cancelAll()
            windowDock.closeAllPanels()
        }

        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )

#if DEBUG
        XCTAssertEqual(
            windowDock.debugWorkspaceFontSizeLineageProbeCount,
            0,
            "Enqueue must only record intent; panel discovery belongs to the bounded drain"
        )
#else
        XCTFail("Workspace font-size probe hooks are only available in DEBUG")
#endif
    }

    func testWorkspaceTerminalFontSizeDrainFollowsWorkspaceMovedToAnotherManager() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let workspace = sourceManager.selectedWorkspace else {
            XCTFail("Expected a source workspace")
            return
        }

        let testPanels = (1...20).map { suffix in
            var configTemplate = CmuxSurfaceConfigTemplate()
            configTemplate.fontSizeLineage = TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
            let panel = TerminalPanel(
                id: UUID(
                    uuidString: String(
                        format: "00000000-0000-4000-8001-%012d",
                        suffix
                    )
                )!,
                workspaceId: workspace.id,
                configTemplate: configTemplate,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            workspace.panels[panel.id] = panel
            return panel
        }
        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: sourceManager,
            schedule: scheduler.schedule(delay:action:)
        )
        defer { coordinator.cancelAll() }

        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.debugFlushOneDrain()
#else
        XCTFail("Workspace font-size coalescer hooks are only available in DEBUG")
        return
#endif

        let adjustedBeforeMove = testPanels.count {
            $0.surface.fontSizeLineageSnapshot()?.basePoints == 19
        }
        XCTAssertGreaterThan(adjustedBeforeMove, 0)
        XCTAssertLessThan(
            adjustedBeforeMove,
            testPanels.count,
            "The first bounded drain should leave terminals for a later turn"
        )

        guard let detachedWorkspace =
                sourceManager.detachWorkspace(tabId: workspace.id) else {
            XCTFail("Expected the source manager to detach the workspace")
            return
        }
        XCTAssertTrue(detachedWorkspace === workspace)
        destinationManager.attachWorkspace(
            detachedWorkspace,
            select: true
        )

#if DEBUG
        coordinator.debugDrainAll()
#endif

        XCTAssertTrue(
            testPanels.allSatisfy {
                $0.surface.fontSizeLineageSnapshot()?.basePoints == 19
            },
            "An in-flight request must follow the workspace object into its destination manager"
        )
    }

    func testWorkspaceTerminalFontSizeMoveSerializesDestinationShortcut() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let workspace = sourceManager.selectedWorkspace else {
            XCTFail("Expected a source workspace")
            return
        }

        let minimum = TerminalFontSizePolicy.minimumRuntimePoints
        let testPanels = workspace.panels.values.compactMap {
            $0 as? TerminalPanel
        } + (1...20).map { suffix in
            var configTemplate = CmuxSurfaceConfigTemplate()
            configTemplate.fontSizeLineage = TerminalFontSizeLineage(
                basePoints: minimum,
                isExplicitOverride: true
            )
            let panel = TerminalPanel(
                id: UUID(
                    uuidString: String(
                        format: "00000000-0000-4000-8002-%012d",
                        suffix
                    )
                )!,
                workspaceId: workspace.id,
                configTemplate: configTemplate,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            workspace.panels[panel.id] = panel
            return panel
        }
        for panel in testPanels {
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: minimum,
                    isExplicitOverride: true
                )
            )
        }

        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        let sourceScheduler = ManualWorkspaceFontSizeDrainScheduler()
        let sourceCoordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: sourceManager,
            arbiter: arbiter,
            schedule: sourceScheduler.schedule(delay:action:)
        )
        let destinationScheduler =
            ManualWorkspaceFontSizeDrainScheduler()
        let destinationCoordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: destinationManager,
            arbiter: arbiter,
            schedule: destinationScheduler.schedule(delay:action:)
        )
        defer {
            sourceCoordinator.cancelAll()
            destinationCoordinator.cancelAll()
        }

        sourceCoordinator.enqueue(
            .relative([1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        sourceCoordinator.debugFlushOneDrain()
#else
        XCTFail("Workspace font-size coalescer hooks are only available in DEBUG")
        return
#endif

        let increasedBeforeMove = testPanels.count {
            $0.surface.fontSizeLineageSnapshot()?.basePoints == minimum + 1
        }
        XCTAssertGreaterThan(increasedBeforeMove, 0)
        XCTAssertLessThan(increasedBeforeMove, testPanels.count)

        guard let detached =
                sourceManager.detachWorkspace(tabId: workspace.id) else {
            XCTFail("Expected the source manager to detach the workspace")
            return
        }
        destinationManager.attachWorkspace(detached, select: true)

        destinationCoordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: false
        )
#if DEBUG
        destinationCoordinator.debugDrainAll()
        sourceCoordinator.debugDrainAll()
#endif

        XCTAssertTrue(
            testPanels.allSatisfy {
                $0.surface.fontSizeLineageSnapshot()?.basePoints == minimum
            },
            "A destination shortcut must run after the source window's older request"
        )
    }

    func testForwardedWorkspaceFontSizeShortcutUsesDestinationWindowDock() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let workspace = sourceManager.selectedWorkspace else {
            XCTFail("Expected a source workspace")
            return
        }

        for _ in 0..<20 {
            let panel = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
            workspace.panels[panel.id] = panel
        }

        let sourceDock = sourceManager.makeWindowDockStore(
            windowId: UUID()
        )
        let destinationDock = destinationManager.makeWindowDockStore(
            windowId: UUID()
        )
        let sourceDockPanel = TerminalPanel(
            workspaceId: sourceDock.workspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        sourceDockPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 10,
                isExplicitOverride: true
            )
        )
        sourceDock.panels[sourceDockPanel.id] = sourceDockPanel
        let destinationDockPanel = TerminalPanel(
            workspaceId: destinationDock.workspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        destinationDockPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )
        destinationDock.panels[destinationDockPanel.id] =
            destinationDockPanel

        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        let sourceScheduler = ManualWorkspaceFontSizeDrainScheduler()
        let sourceCoordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: sourceManager,
            arbiter: arbiter,
            schedule: sourceScheduler.schedule(delay:action:)
        )
        let destinationScheduler =
            ManualWorkspaceFontSizeDrainScheduler()
        let destinationCoordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: destinationManager,
            arbiter: arbiter,
            schedule: destinationScheduler.schedule(delay:action:)
        )
        sourceCoordinator.attachWindowDock(sourceDock)
        destinationCoordinator.attachWindowDock(destinationDock)
        defer {
            sourceCoordinator.cancelAll()
            destinationCoordinator.cancelAll()
            sourceDock.closeAllPanels()
            destinationDock.closeAllPanels()
        }

        sourceCoordinator.enqueue(
            .relative([1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        sourceCoordinator.debugFlushOneDrain()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        guard let detached =
                sourceManager.detachWorkspace(tabId: workspace.id) else {
            XCTFail("Expected the source manager to detach the workspace")
            return
        }
        destinationManager.attachWorkspace(detached, select: true)

        destinationCoordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        sourceCoordinator.debugDrainAll()
        destinationCoordinator.debugDrainAll()
#endif

        XCTAssertEqual(
            sourceDockPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            11,
            "The source shortcut must only adjust the source window Dock"
        )
        XCTAssertEqual(
            destinationDockPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "A forwarded destination shortcut must retain its destination Dock"
        )
    }

    func testLazyDestinationDockTransferUsesForeignRequestCoordinator() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let movedWorkspace = sourceManager.selectedWorkspace,
              let unrelatedWorkspace =
                destinationManager.selectedWorkspace,
              let unrelatedPane =
                unrelatedWorkspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected source and destination workspaces")
            return
        }
        let sourceOtherWorkspace = sourceManager.addTab(select: false)
        for panel in movedWorkspace.panels.values.compactMap({
            $0 as? TerminalPanel
        }) {
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
        }

        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        let sourceCoordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: sourceManager,
            arbiter: arbiter,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:)
        )
        let destinationCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: destinationManager,
                arbiter: arbiter,
                schedule: ManualWorkspaceFontSizeDrainScheduler()
                    .schedule(delay:action:)
            )
        defer {
            sourceCoordinator.cancelAll()
            destinationCoordinator.cancelAll()
        }

        sourceCoordinator.enqueue(
            .relative([1]),
            workspaceId: movedWorkspace.id,
            deferFlush: true
        )
        guard let detachedWorkspace =
                sourceManager.detachWorkspace(
                    tabId: movedWorkspace.id
                ) else {
            XCTFail("Expected the source workspace to detach")
            return
        }
        destinationManager.attachWorkspace(
            detachedWorkspace,
            select: true
        )
        destinationCoordinator.enqueue(
            .relative([-1]),
            workspaceId: movedWorkspace.id,
            deferFlush: true
        )
        sourceCoordinator.enqueue(
            .relative([1]),
            workspaceId: sourceOtherWorkspace.id,
            deferFlush: true
        )

        let destinationDock = destinationManager.makeWindowDockStore(
            windowId: UUID()
        )
        destinationCoordinator.attachWindowDock(destinationDock)
        defer { destinationDock.closeAllPanels() }
        guard let dockPane =
                destinationDock.bonsplitController.focusedPaneId else {
            XCTFail("Expected a destination Dock pane")
            return
        }
        let transferringPanel = TerminalPanel(
            workspaceId: destinationDock.workspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        transferringPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )
        guard destinationDock.attachDetachedSurface(
            makeDormantTerminalTransfer(
                panel: transferringPanel,
                sourceWorkspaceId: destinationDock.workspaceId
            ),
            inPane: dockPane,
            focus: false
        ) != nil,
        let detachedPanel = destinationDock.detachSurface(
            panelId: transferringPanel.id
        ),
        unrelatedWorkspace.attachDetachedSurface(
            detachedPanel,
            inPane: unrelatedPane,
            focus: false
        ) != nil else {
            XCTFail("Expected a Dock terminal to transfer into another workspace")
            return
        }

#if DEBUG
        sourceCoordinator.debugDrainAll()
        destinationCoordinator.debugDrainAll()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        XCTAssertEqual(
            transferringPanel.surface
                .fontSizeLineageSnapshot()?.basePoints,
            19,
            "A lazy Dock transfer must retain the request owned by a foreign coordinator"
        )
    }

    func testForwardedShortcutWaitsForDestinationDockOwner() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let movedWorkspace = sourceManager.selectedWorkspace,
              let destinationWorkspace =
                destinationManager.selectedWorkspace else {
            XCTFail("Expected source and destination workspaces")
            return
        }
        let minimum = TerminalFontSizePolicy.minimumRuntimePoints
        for _ in 0..<20 {
            let panel = TerminalPanel(
                workspaceId: movedWorkspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: minimum,
                    isExplicitOverride: true
                )
            )
            movedWorkspace.panels[panel.id] = panel
        }

        let destinationDock = destinationManager.makeWindowDockStore(
            windowId: UUID()
        )
        let destinationDockPanels = (0..<20).map { _ in
            let panel = TerminalPanel(
                workspaceId: destinationDock.workspaceId,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: minimum,
                    isExplicitOverride: true
                )
            )
            destinationDock.panels[panel.id] = panel
            return panel
        }

        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        let sourceScheduler = ManualWorkspaceFontSizeDrainScheduler()
        let sourceCoordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: sourceManager,
            arbiter: arbiter,
            schedule: sourceScheduler.schedule(delay:action:)
        )
        let destinationScheduler =
            ManualWorkspaceFontSizeDrainScheduler()
        let destinationCoordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: destinationManager,
            arbiter: arbiter,
            schedule: destinationScheduler.schedule(delay:action:)
        )
        destinationCoordinator.attachWindowDock(destinationDock)
        defer {
            sourceCoordinator.cancelAll()
            destinationCoordinator.cancelAll()
            destinationDock.closeAllPanels()
        }

        sourceCoordinator.enqueue(
            .relative([1]),
            workspaceId: movedWorkspace.id,
            deferFlush: true
        )
        destinationCoordinator.enqueue(
            .relative([1]),
            workspaceId: destinationWorkspace.id,
            deferFlush: true
        )
#if DEBUG
        sourceCoordinator.debugFlushOneDrain()
        destinationCoordinator.debugFlushOneDrain()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        guard let detached =
                sourceManager.detachWorkspace(
                    tabId: movedWorkspace.id
                ) else {
            XCTFail("Expected the source manager to detach the workspace")
            return
        }
        destinationManager.attachWorkspace(detached, select: true)
        destinationCoordinator.enqueue(
            .relative([-1]),
            workspaceId: movedWorkspace.id,
            deferFlush: true
        )

#if DEBUG
        sourceCoordinator.debugDrainAll()
        destinationCoordinator.debugDrainAll()
        sourceCoordinator.debugDrainAll()
#endif
        XCTAssertTrue(
            destinationDockPanels.allSatisfy {
                $0.surface.fontSizeLineageSnapshot()?.basePoints
                    == minimum
            },
            "The earlier Dock increase must finish before the later decrease"
        )
    }

    func testLaterDestinationEventCannotBypassDeferredJoin() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let movedWorkspace = sourceManager.selectedWorkspace,
              let destinationWorkspace =
                destinationManager.selectedWorkspace else {
            XCTFail("Expected source and destination workspaces")
            return
        }
        let minimum = TerminalFontSizePolicy.minimumRuntimePoints
        for _ in 0..<20 {
            let panel = TerminalPanel(
                workspaceId: movedWorkspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: minimum,
                    isExplicitOverride: true
                )
            )
            movedWorkspace.panels[panel.id] = panel
        }

        let destinationDock = destinationManager.makeWindowDockStore(
            windowId: UUID()
        )
        let destinationDockPanels = (0..<20).map { _ in
            let panel = TerminalPanel(
                workspaceId: destinationDock.workspaceId,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: minimum,
                    isExplicitOverride: true
                )
            )
            destinationDock.panels[panel.id] = panel
            return panel
        }

        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        let sourceCoordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: sourceManager,
            arbiter: arbiter,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:)
        )
        let destinationCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: destinationManager,
                arbiter: arbiter,
                schedule: ManualWorkspaceFontSizeDrainScheduler()
                    .schedule(delay:action:)
            )
        destinationCoordinator.attachWindowDock(destinationDock)
        defer {
            sourceCoordinator.cancelAll()
            destinationCoordinator.cancelAll()
            destinationDock.closeAllPanels()
        }

        sourceCoordinator.enqueue(
            .relative([1, -1]),
            workspaceId: movedWorkspace.id,
            deferFlush: true
        )
        destinationCoordinator.enqueue(
            .relative([1, -1]),
            workspaceId: destinationWorkspace.id,
            deferFlush: true
        )
#if DEBUG
        sourceCoordinator.debugFlushOneDrain()
        destinationCoordinator.debugFlushOneDrain()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        guard let detached =
                sourceManager.detachWorkspace(
                    tabId: movedWorkspace.id
                ) else {
            XCTFail("Expected the source manager to detach the workspace")
            return
        }
        destinationManager.attachWorkspace(detached, select: true)
        destinationCoordinator.enqueue(
            .relative([-1]),
            workspaceId: movedWorkspace.id,
            deferFlush: true
        )
        destinationCoordinator.enqueue(
            .relative([1]),
            workspaceId: destinationWorkspace.id,
            deferFlush: true
        )

#if DEBUG
        sourceCoordinator.debugDrainAll()
        destinationCoordinator.debugDrainAll()
        sourceCoordinator.debugDrainAll()
#endif
        XCTAssertTrue(
            destinationDockPanels.allSatisfy {
                $0.surface.fontSizeLineageSnapshot()?.basePoints
                    == minimum + 1
            },
            "A later event sharing the Dock must wait behind the deferred join"
        )
    }

    func testTransferredDescendantPreservesEveryReconciledRequestToken() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let pane = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected a workspace pane")
            return
        }

        var movablePanels: [TerminalPanel] = []
        for _ in 0..<20 {
            let panel = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
            let transfer = makeDormantTerminalTransfer(
                panel: panel,
                sourceWorkspaceId: workspace.id
            )
            guard workspace.attachDetachedSurface(
                transfer,
                inPane: pane,
                focus: false
            ) != nil else {
                XCTFail("Expected a movable terminal")
                return
            }
            movablePanels.append(panel)
        }

        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: scheduler.schedule(delay:action:)
        )
        defer { coordinator.cancelAll() }
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.debugFlushOneDrain()
#endif
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )

        guard let movedPanel = movablePanels.first(where: {
            $0.surface.fontSizeLineageSnapshot()?.basePoints == 20
        }),
        let detached = workspace.detachSurface(panelId: movedPanel.id),
        workspace.attachDetachedSurface(
            detached,
            inPane: pane,
            focus: false
        ) != nil,
        let descendant = workspace.newTerminalSplit(
            from: movedPanel.id,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected a transferred terminal and its descendant")
            return
        }
        XCTAssertEqual(
            descendant.surface.fontSizeLineageSnapshot()?.basePoints,
            18,
            "The descendant must inherit both reconciled requests"
        )

#if DEBUG
        coordinator.debugDrainAll()
#endif
        XCTAssertEqual(
            movedPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            18
        )
        XCTAssertEqual(
            descendant.surface.fontSizeLineageSnapshot()?.basePoints,
            18,
            "A queued request already present in inherited lineage must not replay"
        )
    }

    func testSourceWindowTeardownPreservesMovedWorkspaceFontSizeWork() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let workspace = sourceManager.selectedWorkspace else {
            XCTFail("Expected a source workspace")
            return
        }
        let testPanels = (0..<20).map { _ in
            let panel = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
            workspace.panels[panel.id] = panel
            return panel
        }
        let sourceContext = AppDelegate.MainWindowContext(
            windowId: UUID(),
            tabManager: sourceManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: nil,
            cmuxConfigStore: nil,
            window: nil,
            workspaceTerminalFontSizeArbiter:
                WorkspaceTerminalFontSizeCoordinator.Arbiter()
        )
        let coordinator =
            sourceContext.workspaceTerminalFontSizeCoordinator
        defer { coordinator.cancelAll() }

        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.debugFlushOneDrain()
#endif
        guard let detached =
                sourceManager.detachWorkspace(tabId: workspace.id) else {
            XCTFail("Expected the source manager to detach the workspace")
            return
        }
        destinationManager.attachWorkspace(detached, select: true)

        sourceContext.teardownWindowDock()
#if DEBUG
        coordinator.debugDrainAll()
#endif
        XCTAssertTrue(
            testPanels.allSatisfy {
                $0.surface.fontSizeLineageSnapshot()?.basePoints == 19
            },
            "Closing the source window must not cancel destination-owned work"
        )
    }

    func testWorkspaceTerminalFontSizeDrainReconcilesMovedOutTerminal() {
        let manager = TabManager()
        guard let sourceWorkspace = manager.selectedWorkspace,
              let sourcePane =
                sourceWorkspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected a source workspace pane")
            return
        }
        let destinationWorkspace = manager.addTab(select: false)
        guard let destinationPane =
                destinationWorkspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected a destination workspace pane")
            return
        }

        var movablePanels: [TerminalPanel] = []
        for suffix in 1...20 {
            var configTemplate = CmuxSurfaceConfigTemplate()
            configTemplate.fontSizeLineage = TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
            let panel = TerminalPanel(
                id: UUID(
                    uuidString: String(
                        format: "00000000-0000-4000-8003-%012d",
                        suffix
                    )
                )!,
                workspaceId: sourceWorkspace.id,
                configTemplate: configTemplate,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            let transfer = makeDormantTerminalTransfer(
                panel: panel,
                sourceWorkspaceId: sourceWorkspace.id
            )
            guard sourceWorkspace.attachDetachedSurface(
                transfer,
                inPane: sourcePane,
                focus: false
            ) != nil else {
                XCTFail("Expected a movable source terminal")
                return
            }
            movablePanels.append(panel)
        }

        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: scheduler.schedule(delay:action:)
        )
        defer { coordinator.cancelAll() }
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: sourceWorkspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.debugFlushOneDrain()
#endif

        guard let unvisitedPanel = movablePanels.first(where: {
            $0.surface.fontSizeLineageSnapshot()?.basePoints == 20
        }),
        let detached = sourceWorkspace.detachSurface(
            panelId: unvisitedPanel.id
        ),
        destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        ) != nil else {
            XCTFail("Expected an unvisited terminal to move between workspaces")
            return
        }

#if DEBUG
        coordinator.debugDrainAll()
#endif
        XCTAssertEqual(
            unvisitedPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "A terminal present when the request began must carry that request through a move"
        )
    }

    func testWorkspaceTerminalFontSizeDrainAppliesToUnrelatedEnteringTerminal() {
        let manager = TabManager()
        guard let sourceWorkspace = manager.selectedWorkspace,
              let sourcePane =
                sourceWorkspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected a source workspace pane")
            return
        }
        let destinationWorkspace = manager.addTab(select: false)
        guard let destinationPane =
                destinationWorkspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected a destination workspace pane")
            return
        }

        let enteringPanel = TerminalPanel(
            workspaceId: sourceWorkspace.id,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        enteringPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )
        guard sourceWorkspace.attachDetachedSurface(
            makeDormantTerminalTransfer(
                panel: enteringPanel,
                sourceWorkspaceId: sourceWorkspace.id
            ),
            inPane: sourcePane,
            focus: false
        ) != nil else {
            XCTFail("Expected an unrelated source terminal")
            return
        }

        for _ in 0..<20 {
            let panel = TerminalPanel(
                workspaceId: destinationWorkspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
            guard destinationWorkspace.attachDetachedSurface(
                makeDormantTerminalTransfer(
                    panel: panel,
                    sourceWorkspaceId: destinationWorkspace.id
                ),
                inPane: destinationPane,
                focus: false
            ) != nil else {
                XCTFail("Expected a busy destination terminal")
                return
            }
        }

        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:)
        )
        defer { coordinator.cancelAll() }
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: destinationWorkspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.debugFlushOneDrain()
#endif

        guard let detached = sourceWorkspace.detachSurface(
            panelId: enteringPanel.id
        ),
        destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        ) != nil else {
            XCTFail("Expected the unrelated terminal to enter the destination")
            return
        }

#if DEBUG
        coordinator.debugDrainAll()
#endif
        XCTAssertEqual(
            enteringPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "An unrelated entering terminal must receive outstanding destination work"
        )
    }

    func testEnteringTerminalReconcilesEachOutstandingRequestToken() {
        let manager = TabManager()
        guard let sourceWorkspace = manager.selectedWorkspace,
              let sourcePane =
                sourceWorkspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected a source workspace pane")
            return
        }
        let destinationWorkspace = manager.addTab(select: false)
        guard let destinationPane =
                destinationWorkspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected a destination workspace pane")
            return
        }

        var movablePanels: [TerminalPanel] = []
        for _ in 0..<20 {
            let panel = TerminalPanel(
                workspaceId: sourceWorkspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
            guard sourceWorkspace.attachDetachedSurface(
                makeDormantTerminalTransfer(
                    panel: panel,
                    sourceWorkspaceId: sourceWorkspace.id
                ),
                inPane: sourcePane,
                focus: false
            ) != nil else {
                XCTFail("Expected a movable source terminal")
                return
            }
            movablePanels.append(panel)
        }

        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:)
        )
        defer { coordinator.cancelAll() }
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: sourceWorkspace.id,
            deferFlush: true
        )
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: destinationWorkspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.debugFlushOneDrain()
#endif

        guard let movedPanel = movablePanels.first(where: {
            $0.surface.fontSizeLineageSnapshot()?.basePoints == 20
        }),
        let detached = sourceWorkspace.detachSurface(
            panelId: movedPanel.id
        ),
        destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        ) != nil else {
            XCTFail("Expected an unvisited source terminal to move")
            return
        }
        XCTAssertEqual(
            movedPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            18,
            "Source reconciliation must not suppress a distinct destination request"
        )

#if DEBUG
        coordinator.debugDrainAll()
#endif
        XCTAssertEqual(
            movedPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            18,
            "Each outstanding request must apply exactly once"
        )
    }

    func testEnteringTerminalReconcilesOutstandingRequestsWithinDrainBudgets() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected an initial workspace")
            return
        }
        let markerPanel = TerminalPanel(
            workspaceId: workspace.id,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        markerPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )
        let enteringPanel = TerminalPanel(
            workspaceId: workspace.id,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        enteringPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )

        var enteringPanelApplyCount = 0
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:),
            applyChange: { change, panel, configuredRuntimePoints in
                if panel === enteringPanel {
                    enteringPanelApplyCount += 1
                }
                return cmuxApplyTerminalFontSizeChange(
                    change,
                    to: panel,
                    configuredRuntimePoints: configuredRuntimePoints
                )
            }
        )
        defer { coordinator.cancelAll() }

        for _ in 0..<40 {
            coordinator.enqueue(
                .relative([-1]),
                workspaceId: workspace.id,
                deferFlush: true
            )
            coordinator.terminalDidEnterWorkspace(
                markerPanel,
                workspace: workspace
            )
        }
        coordinator.terminalDidEnterWorkspace(
            enteringPanel,
            workspace: workspace
        )

#if DEBUG
        XCTAssertLessThanOrEqual(
            coordinator.debugLastSynchronousTransferRequestVisitCount,
            WorkspaceTerminalFontSizeDrainBudget
                .maximumRequestVisitsPerDrain,
            "A transfer callback must stay inside one request-visit budget"
        )
        XCTAssertLessThanOrEqual(
            enteringPanelApplyCount,
            WorkspaceTerminalFontSizeDrainBudget
                .maximumLiveActionsPerDrain,
            "A transfer callback must keep native work inside one drain budget"
        )
        let callbackApplyCount = enteringPanelApplyCount
        coordinator.debugFlushOneDrain()
        XCTAssertLessThanOrEqual(
            enteringPanelApplyCount - callbackApplyCount,
            WorkspaceTerminalFontSizeDrainBudget
                .maximumLiveActionsPerDrain,
            "One drain must keep transfer actions inside its native-action budget"
        )
        coordinator.debugDrainAll()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        guard let enteringBasePoints =
                enteringPanel.surface
                    .fontSizeLineageSnapshot()?.basePoints else {
            XCTFail("Expected the entering terminal to retain font lineage")
            return
        }
        XCTAssertEqual(
            enteringBasePoints,
            TerminalFontSizePolicy.minimumRuntimePoints,
            accuracy: 0.001,
            "Budgeted transfer work must preserve every request in order"
        )
    }

    func testFailedTransferFontSizeActionRetriesBeforeRecordingProvenance() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelID = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelID) else {
            XCTFail("Expected an initial workspace terminal")
            return
        }
        panel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )

        var applyAttemptCount = 0
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:),
            applyChange: { change, candidate, configuredRuntimePoints in
                guard candidate === panel else { return .applied }
                applyAttemptCount += 1
                guard applyAttemptCount > 1 else { return .failed }
                return cmuxApplyTerminalFontSizeChange(
                    change,
                    to: candidate,
                    configuredRuntimePoints: configuredRuntimePoints
                )
            }
        )
        defer { coordinator.cancelAll() }
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )

        coordinator.terminalDidEnterWorkspace(
            panel,
            workspace: workspace
        )
        coordinator.terminalDidEnterWorkspace(
            panel,
            workspace: workspace
        )

        XCTAssertEqual(
            applyAttemptCount,
            2,
            "A failed transfer action must remain eligible for reconciliation"
        )
        XCTAssertEqual(
            panel.surface.fontSizeLineageSnapshot()?.basePoints,
            19
        )
    }

    func testFailedStationaryFontSizeActionRetriesBeforeRetiringRequest() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelID = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelID) else {
            XCTFail("Expected an initial workspace terminal")
            return
        }
        panel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )

        var applyAttemptCount = 0
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:),
            applyChange: { change, candidate, configuredRuntimePoints in
                guard candidate === panel else {
                    return .alreadySatisfied
                }
                applyAttemptCount += 1
                guard applyAttemptCount > 1 else { return .failed }
                return cmuxApplyTerminalFontSizeChange(
                    change,
                    to: candidate,
                    configuredRuntimePoints: configuredRuntimePoints
                )
            }
        )
        defer { coordinator.cancelAll() }

        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.debugDrainAll()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        XCTAssertEqual(
            applyAttemptCount,
            2,
            "A stationary mutation failure must remain pending for a later drain"
        )
        XCTAssertEqual(
            panel.surface.fontSizeLineageSnapshot()?.basePoints,
            19
        )
    }

    func testReconciledFailedFontSizeActionDoesNotReplayRelativeDelta() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelID = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelID) else {
            XCTFail("Expected an initial workspace terminal")
            return
        }
        panel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )

        var applyAttemptCount = 0
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:),
            applyChange: { change, candidate, configuredRuntimePoints in
                guard candidate === panel else {
                    return .alreadySatisfied
                }
                applyAttemptCount += 1
                let outcome = cmuxApplyTerminalFontSizeChange(
                    change,
                    to: candidate,
                    configuredRuntimePoints: configuredRuntimePoints
                )
                return applyAttemptCount == 1 ? .failed : outcome
            }
        )
        defer { coordinator.cancelAll() }

        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.debugDrainAll()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        XCTAssertEqual(
            applyAttemptCount,
            1,
            "Observed target state must reconcile a fallible native action"
        )
        XCTAssertEqual(
            panel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "A reconciled relative mutation must not replay its delta"
        )
    }

    func testPersistentFontSizeFailureBacksOffThenWaitsForSignal() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelID = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelID) else {
            XCTFail("Expected an initial workspace terminal")
            return
        }
        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        var applyAttemptCount = 0
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: scheduler.schedule(delay:action:),
            applyChange: { _, candidate, _ in
                guard candidate === panel else {
                    return .alreadySatisfied
                }
                applyAttemptCount += 1
                return .failed
            }
        )
        defer { coordinator.cancelAll() }

        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.debugFlushOneDrain()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        XCTAssertEqual(applyAttemptCount, 1)
        XCTAssertEqual(scheduler.delays.count, 2)
        XCTAssertEqual(
            scheduler.delays[1],
            0.05,
            accuracy: 0.001,
            "The only automatic retry must use a nonzero backoff"
        )

        scheduler.fire(at: 1)

        XCTAssertEqual(applyAttemptCount, 2)
        XCTAssertEqual(
            scheduler.delays.count,
            2,
            "A persistent failure must park until an external retry signal"
        )
    }

    func testHibernatedFontFollowerPredictsFromConfiguredBaseline() {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(12, isExplicitOverride: false)
        let panel = TerminalPanel(
            workspaceId: UUID(),
            configTemplate: template,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        panel.surface.surface =
            UnsafeMutableRawPointer(bitPattern: 0x8791)
        panel.surface.surface = nil
        panel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 12,
                isExplicitOverride: false
            )
        )

        let context = TerminalFontSizeChangeInheritanceContext(
            token: UUID(),
            change: .relative([-1]),
            configuredRuntimePoints: 16,
            preferredSourcePanel: panel,
            fallbackLineage: nil
        )

        XCTAssertEqual(
            context.fallbackLineage,
            TerminalFontSizeLineage(
                basePoints: 15,
                isExplicitOverride: true
            )
        )
        XCTAssertEqual(
            context.inheritedLineage(from: panel),
            context.fallbackLineage,
            "Inheritance and mutation must use the same hibernated baseline"
        )
    }

    func testFailedTransferRetriesAfterPanelLeavesCoordinatorOwnership() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let sourceWorkspace = sourceManager.selectedWorkspace,
              let sourcePane =
                sourceWorkspace.bonsplitController.focusedPaneId,
              let destinationWorkspace =
                destinationManager.selectedWorkspace,
              let destinationPane =
                destinationWorkspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected source and destination workspace panes")
            return
        }

        let panel = TerminalPanel(
            workspaceId: sourceWorkspace.id,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        panel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )
        guard sourceWorkspace.attachDetachedSurface(
            makeDormantTerminalTransfer(
                panel: panel,
                sourceWorkspaceId: sourceWorkspace.id
            ),
            inPane: sourcePane,
            focus: false
        ) != nil else {
            XCTFail("Expected a movable source terminal")
            return
        }

        var applyAttemptCount = 0
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: sourceManager,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:),
            applyChange: { change, candidate, configuredRuntimePoints in
                guard candidate === panel else {
                    return .alreadySatisfied
                }
                applyAttemptCount += 1
                guard applyAttemptCount > 1 else { return .failed }
                return cmuxApplyTerminalFontSizeChange(
                    change,
                    to: candidate,
                    configuredRuntimePoints: configuredRuntimePoints
                )
            }
        )
        defer { coordinator.cancelAll() }
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: sourceWorkspace.id,
            deferFlush: true
        )

        guard let detached = sourceWorkspace.detachSurface(
            panelId: panel.id
        ),
        destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        ) != nil else {
            XCTFail("Expected the terminal to leave coordinator ownership")
            return
        }
#if DEBUG
        coordinator.debugDrainAll()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        XCTAssertEqual(
            applyAttemptCount,
            2,
            "The source coordinator must retain a failed transfer until retry"
        )
        XCTAssertEqual(
            panel.surface.fontSizeLineageSnapshot()?.basePoints,
            19
        )
    }

    func testSessionRestoreDuringActiveDrainReceivesOutstandingChange() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let pane = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected an initial workspace pane")
            return
        }
        for suffix in 1...20 {
            let panel = TerminalPanel(
                id: UUID(
                    uuidString: String(
                        format: "00000000-0000-4000-8009-%012d",
                        suffix
                    )
                )!,
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
            workspace.panels[panel.id] = panel
        }

        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:)
        )
        defer { coordinator.cancelAll() }
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.debugFlushOneDrain()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        guard let restoredPanel = workspace.newTerminalSurface(
            inPane: pane,
            focus: false,
            runtimeSpawnPolicy: .pacedSessionRestore,
            terminalFontSizeCreationPolicy:
                .sessionRestore(overrideBasePoints: 12)
        ) else {
            XCTFail("Expected a session-restored terminal")
            return
        }
#if DEBUG
        coordinator.debugDrainAll()
#endif

        XCTAssertEqual(
            restoredPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            11,
            "A restored terminal created after discovery starts must join the active request"
        )
    }

    func testFailedTransferFontSizeActionBlocksLaterRequestAtNativeBound() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelID = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelID) else {
            XCTFail("Expected an initial workspace terminal")
            return
        }
        let maximumBasePoints =
            CmuxSurfaceConfigTemplate.baseFontSize(
                fromRuntimePoints:
                    TerminalFontSizePolicy.maximumRuntimePoints,
                percent: GlobalFontMagnification.storedPercent
            )
        panel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: maximumBasePoints,
                isExplicitOverride: true
            )
        )
        let markerPanel = TerminalPanel(
            workspaceId: workspace.id,
            runtimeSpawnPolicy: .pacedSessionRestore
        )

        var targetChanges: [WorkspaceTerminalFontSizeChange] = []
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:),
            applyChange: { change, candidate, configuredRuntimePoints in
                guard candidate === panel else {
                    return .alreadySatisfied
                }
                targetChanges.append(change)
                guard targetChanges.count > 1 else {
                    return .failed
                }
                return cmuxApplyTerminalFontSizeChange(
                    change,
                    to: candidate,
                    configuredRuntimePoints: configuredRuntimePoints
                )
            }
        )
        defer { coordinator.cancelAll() }

        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
        coordinator.terminalWillLeaveWorkspace(
            markerPanel,
            workspace: workspace
        )
        coordinator.enqueue(
            .relative([1]),
            workspaceId: workspace.id,
            deferFlush: true
        )

        coordinator.terminalDidEnterWorkspace(
            panel,
            workspace: workspace
        )
        coordinator.terminalDidEnterWorkspace(
            panel,
            workspace: workspace
        )

        XCTAssertEqual(
            targetChanges,
            [
                .relative([-1]),
                .relative([-1]),
                .relative([1]),
            ],
            "A later transfer request must not overtake a failed mutation"
        )
        guard let finalBasePoints =
                panel.surface.fontSizeLineageSnapshot()?.basePoints else {
            XCTFail("Expected the terminal to retain font-size lineage")
            return
        }
        XCTAssertEqual(
            finalBasePoints,
            maximumBasePoints,
            accuracy: 0.001
        )
    }

    func testWindowDockFontSizeDrainAppliesToUnrelatedEnteringTerminal() {
        let manager = TabManager()
        guard let requestedWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected a requested workspace")
            return
        }
        let sourceWorkspace = manager.addTab(select: false)
        guard let sourcePane =
                sourceWorkspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected an unrelated source workspace pane")
            return
        }
        let windowDock = manager.makeWindowDockStore(windowId: UUID())
        guard let dockPane =
                windowDock.bonsplitController.focusedPaneId else {
            XCTFail("Expected a window Dock pane")
            return
        }

        let enteringPanel = TerminalPanel(
            workspaceId: sourceWorkspace.id,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        enteringPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )
        guard sourceWorkspace.attachDetachedSurface(
            makeDormantTerminalTransfer(
                panel: enteringPanel,
                sourceWorkspaceId: sourceWorkspace.id
            ),
            inPane: sourcePane,
            focus: false
        ) != nil else {
            XCTFail("Expected an unrelated source terminal")
            return
        }

        for _ in 0..<20 {
            let panel = TerminalPanel(
                workspaceId: windowDock.workspaceId,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
            guard windowDock.attachDetachedSurface(
                makeDormantTerminalTransfer(
                    panel: panel,
                    sourceWorkspaceId: windowDock.workspaceId
                ),
                inPane: dockPane,
                focus: false
            ) != nil else {
                XCTFail("Expected a busy Dock terminal")
                return
            }
        }

        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:)
        )
        coordinator.attachWindowDock(windowDock)
        defer {
            coordinator.cancelAll()
            windowDock.closeAllPanels()
        }
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: requestedWorkspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.debugFlushOneDrain()
#endif

        guard let detached = sourceWorkspace.detachSurface(
            panelId: enteringPanel.id
        ),
        windowDock.attachDetachedSurface(
            detached,
            inPane: dockPane,
            focus: false
        ) != nil else {
            XCTFail("Expected the unrelated terminal to enter the Dock")
            return
        }

#if DEBUG
        coordinator.debugDrainAll()
#endif
        XCTAssertEqual(
            enteringPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "An unrelated entering terminal must receive outstanding Dock work"
        )
    }

    func testFinishedDockRequestProtectsTransferUntilWorkspaceSiblingFinishes() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let workspacePane =
                workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected an initial workspace pane")
            return
        }
        let windowDock = manager.makeWindowDockStore(windowId: UUID())
        guard let dockPane =
                windowDock.bonsplitController.focusedPaneId else {
            XCTFail("Expected a Window Dock pane")
            return
        }

        for _ in 0..<64 {
            let panel = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
            guard workspace.attachDetachedSurface(
                makeDormantTerminalTransfer(
                    panel: panel,
                    sourceWorkspaceId: workspace.id
                ),
                inPane: workspacePane,
                focus: false
            ) != nil else {
                XCTFail("Expected a busy workspace terminal")
                return
            }
        }

        let dockPanel = TerminalPanel(
            workspaceId: windowDock.workspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        dockPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )
        guard windowDock.attachDetachedSurface(
            makeDormantTerminalTransfer(
                panel: dockPanel,
                sourceWorkspaceId: windowDock.workspaceId
            ),
            inPane: dockPane,
            focus: false
        ) != nil else {
            XCTFail("Expected a Window Dock terminal")
            return
        }

        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:)
        )
        coordinator.attachWindowDock(windowDock)
        defer {
            coordinator.cancelAll()
            windowDock.closeAllPanels()
        }
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.debugFlushOneDrain()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        XCTAssertEqual(
            dockPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "The first bounded drain must finish the one-terminal Dock request"
        )
        guard let detached = windowDock.detachSurface(
            panelId: dockPanel.id
        ),
        workspace.attachDetachedSurface(
            detached,
            inPane: workspacePane,
            focus: false
        ) != nil else {
            XCTFail("Expected the adjusted Dock terminal to enter the workspace")
            return
        }

        XCTAssertEqual(
            dockPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "A finished Dock sibling must still prove the shared event was applied"
        )
#if DEBUG
        coordinator.debugDrainAll()
#endif
        XCTAssertEqual(
            dockPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "The shared batch must apply once after every sibling finishes"
        )
    }

    func testWorkspaceTransferDoesNotCoverAnotherWorkspacesDockEvent() {
        let manager = TabManager()
        guard let firstWorkspace = manager.selectedWorkspace,
              let firstPanelID = firstWorkspace.focusedPanelId,
              let firstPanel =
                firstWorkspace.terminalPanel(for: firstPanelID) else {
            XCTFail("Expected an initial workspace terminal")
            return
        }
        let secondWorkspace = manager.addTab(select: false)
        let windowDock = manager.makeWindowDockStore(windowId: UUID())
        guard let dockPane =
                windowDock.bonsplitController.focusedPaneId else {
            XCTFail("Expected a Window Dock pane")
            return
        }
        firstPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )

        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:)
        )
        coordinator.attachWindowDock(windowDock)
        defer {
            coordinator.cancelAll()
            windowDock.closeAllPanels()
        }
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: firstWorkspace.id,
            deferFlush: true
        )
        coordinator.enqueue(
            .relative([1]),
            workspaceId: secondWorkspace.id,
            deferFlush: true
        )

        guard let detached = firstWorkspace.detachSurface(
            panelId: firstPanel.id
        ),
        windowDock.attachDetachedSurface(
            detached,
            inPane: dockPane,
            focus: false
        ) != nil else {
            XCTFail("Expected the first workspace terminal to enter the Dock")
            return
        }

        XCTAssertEqual(
            firstPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            20,
            "The Dock must apply the second workspace's uncovered event"
        )
#if DEBUG
        coordinator.debugDrainAll()
#endif
        XCTAssertEqual(
            firstPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            20
        )
    }

    func testTransferOnlyDockTerminalSeedsTerminalFreeWorkspace() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let firstPanelID = workspace.focusedPanelId,
              let workspacePane =
                workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected an initial workspace pane")
            return
        }
        guard workspace.newBrowserSurface(
            inPane: workspacePane,
            url: URL(string: "about:blank"),
            focus: false,
            creationPolicy: .restoration
        ) != nil,
        workspace.closePanel(firstPanelID, force: true) else {
            XCTFail("Expected a terminal-free workspace")
            return
        }

        let windowDock = manager.makeWindowDockStore(windowId: UUID())
        guard let dockPane =
                windowDock.bonsplitController.focusedPaneId else {
            XCTFail("Expected a Window Dock pane")
            return
        }
        let dockPanel = TerminalPanel(
            workspaceId: windowDock.workspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        dockPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )
        guard windowDock.attachDetachedSurface(
            makeDormantTerminalTransfer(
                panel: dockPanel,
                sourceWorkspaceId: windowDock.workspaceId
            ),
            inPane: dockPane,
            focus: false
        ) != nil else {
            XCTFail("Expected a Window Dock terminal")
            return
        }

        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:)
        )
        coordinator.attachWindowDock(windowDock)
        defer {
            coordinator.cancelAll()
            windowDock.closeAllPanels()
        }
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
        guard let detached = windowDock.detachSurface(
            panelId: dockPanel.id
        ) else {
            XCTFail("Expected the Dock terminal to detach")
            return
        }
#if DEBUG
        coordinator.debugDrainAll()
#endif
        withExtendedLifetime(detached) {}

        guard let inheritedPanel = workspace.newTerminalSurface(
            inPane: workspacePane,
            focus: false,
            runtimeSpawnPolicy: .pacedSessionRestore
        ) else {
            XCTFail("Expected an inherited workspace terminal")
            return
        }
        XCTAssertEqual(
            inheritedPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "Transfer-only Dock participation must seed its adjusted lineage"
        )
    }

    func testWorkspaceTerminalFontSizeDrainDoesNotDoubleApplyDockMove() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let destinationPane =
                workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected a workspace pane")
            return
        }
        let windowDock = manager.makeWindowDockStore(windowId: UUID())
        guard let dockPane = windowDock.bonsplitController.focusedPaneId else {
            XCTFail("Expected a window Dock pane")
            return
        }

        var dockPanels: [TerminalPanel] = []
        for suffix in 1...20 {
            var configTemplate = CmuxSurfaceConfigTemplate()
            configTemplate.fontSizeLineage = TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
            let panel = TerminalPanel(
                id: UUID(
                    uuidString: String(
                        format: "00000000-0000-4000-8004-%012d",
                        suffix
                    )
                )!,
                workspaceId: windowDock.workspaceId,
                configTemplate: configTemplate,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            let transfer = makeDormantTerminalTransfer(
                panel: panel,
                sourceWorkspaceId: windowDock.workspaceId
            )
            guard windowDock.attachDetachedSurface(
                transfer,
                inPane: dockPane,
                focus: false
            ) != nil else {
                XCTFail("Expected a movable Dock terminal")
                return
            }
            dockPanels.append(panel)
        }

        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: scheduler.schedule(delay:action:)
        )
        coordinator.attachWindowDock(windowDock)
        defer { coordinator.cancelAll() }
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.debugFlushOneDrain()
#endif

        guard let visitedDockPanel = dockPanels.first(where: {
            $0.surface.fontSizeLineageSnapshot()?.basePoints == 19
        }),
        let detached = windowDock.detachSurface(
            panelId: visitedDockPanel.id
        ),
        workspace.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        ) != nil else {
            XCTFail("Expected an adjusted Dock terminal to move into the workspace")
            return
        }

#if DEBUG
        coordinator.debugDrainAll()
#endif
        XCTAssertEqual(
            visitedDockPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "Moving between two request targets must preserve one application"
        )

        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: false
        )
#if DEBUG
        coordinator.debugDrainAll()
#endif
        XCTAssertEqual(
            visitedDockPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            18,
            "A transfer marker must not suppress a later destination request"
        )
    }

    func testPendingFontSizeEventDoesNotReplayOnMoveIntoWindowDock() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelID = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelID) else {
            XCTFail("Expected a workspace terminal")
            return
        }
        let windowDock = manager.makeWindowDockStore(windowId: UUID())
        guard let dockPane =
                windowDock.bonsplitController.focusedPaneId else {
            XCTFail("Expected a Window Dock pane")
            return
        }
        panel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )

        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:)
        )
        coordinator.attachWindowDock(windowDock)
        defer { coordinator.cancelAll() }
        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )

        guard let detached = workspace.detachSurface(panelId: panel.id),
              windowDock.attachDetachedSurface(
                detached,
                inPane: dockPane,
                focus: false
              ) != nil else {
            XCTFail("Expected the terminal to move into Window Dock")
            return
        }
        XCTAssertEqual(
            panel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "One event shared by workspace and Window Dock must apply once"
        )

#if DEBUG
        coordinator.debugDrainAll()
#endif
        XCTAssertEqual(
            panel.surface.fontSizeLineageSnapshot()?.basePoints,
            19
        )
    }

    func testClosingWindowCancelsPendingWorkspaceTerminalFontSizeChange() {
        withTemporaryShortcut(action: .decreaseWorkspaceTerminalFontSize) {
            guard let appDelegate = AppDelegate.shared else {
                XCTFail("Expected AppDelegate.shared")
                return
            }

            let windowId = appDelegate.createMainWindow()
            guard let window = window(withId: windowId),
                  let repeatedEvent = makeKeyDownEvent(
                    key: "-",
                    modifiers: [.command, .control],
                    keyCode: 27,
                    windowNumber: window.windowNumber,
                    isARepeat: true
                  ) else {
                XCTFail("Expected a window and repeated Cmd+Ctrl+- event")
                closeWindow(withId: windowId)
                return
            }

            let windowDock = appDelegate.windowDock(forWindowId: windowId)
            let dockPanels = (0..<12).map { _ in
                var configTemplate = CmuxSurfaceConfigTemplate()
                configTemplate.fontSizeLineage = TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
                let panel = TerminalPanel(
                    workspaceId: windowDock.workspaceId,
                    configTemplate: configTemplate,
                    runtimeSpawnPolicy: .pacedSessionRestore
                )
                windowDock.panels[panel.id] = panel
                return panel
            }

#if DEBUG
            appDelegate.debugFlushPendingWorkspaceTerminalFontSizeChanges()
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEvent))
            appDelegate.debugFlushPendingWorkspaceTerminalFontSizeChanges()
            XCTAssertGreaterThan(
                appDelegate.debugPendingWorkspaceTerminalFontSizeChangeCount,
                0
            )

            let lineagesAtClose = dockPanels.map {
                $0.surface.fontSizeLineageSnapshot()
            }
            window.performClose(nil)

            XCTAssertEqual(
                appDelegate.debugPendingWorkspaceTerminalFontSizeChangeCount,
                0,
                "Window teardown must cancel its font-size coordinator"
            )
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            XCTAssertEqual(
                dockPanels.map { $0.surface.fontSizeLineageSnapshot() },
                lineagesAtClose,
                "A scheduled drain must not mutate panels after their window closes"
            )
#else
            XCTFail("Workspace font-size coalescer hooks are only available in DEBUG")
            closeWindow(withId: windowId)
#endif
        }
    }

    func testPendingWorkspaceTerminalFontSizeChangePreservesResetOrdering() {
        var change = WorkspaceTerminalFontSizeChange.relative([-1])
        change.appendAdjustment(-1)
        XCTAssertEqual(change, .relative([-2]))

        change.appendReset()
        XCTAssertEqual(change, .resetThen([]))

        change.appendAdjustment(1)
        XCTAssertEqual(change, .resetThen([1]))

        change.appendReset()
        XCTAssertEqual(change, .resetThen([]))
    }

    func testPendingWorkspaceTerminalFontSizeChangePreservesOppositeDirections() {
        var change = WorkspaceTerminalFontSizeChange.relative([1])
        change.appendAdjustment(-1)

        XCTAssertEqual(change, .relative([1, -1]))
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

    private func storedFloatCount(in value: Any) -> Int {
        if value is Float32 {
            return 1
        }
        return Mirror(reflecting: value).children.reduce(into: 0) {
            $0 += storedFloatCount(in: $1.value)
        }
    }

    private func makeDormantTerminalTransfer(
        panel: TerminalPanel,
        sourceWorkspaceId: UUID
    ) -> Workspace.DetachedSurfaceTransfer {
        Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            panelId: panel.id,
            panel: panel,
            title: panel.displayTitle,
            icon: panel.displayIcon,
            iconImageData: nil,
            kind: "terminal",
            isLoading: false,
            isPinned: false,
            directory: nil,
            directoryIsTrustedRemoteReport: false,
            directoryDisplayLabel: nil,
            ttyName: nil,
            cachedTitle: nil,
            customTitle: nil,
            customTitleSource: nil,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: nil,
            restorableAgentResumeState: nil,
            restoredAgentCompletedGeneration: nil,
            shellActivityState: nil,
            restoredResumeSessionWorkingDirectory: nil,
            resumeBinding: nil,
            agentRuntime: nil,
            isRemoteTerminal: false,
            remoteRelayPort: nil,
            remotePTYSessionID: nil,
            remoteCleanupConfiguration: nil
        )
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

@MainActor
private final class ManualWorkspaceFontSizeDrainScheduler {
    private struct ScheduledDrain {
        var isCancelled = false
        let action: @MainActor () -> Void
    }

    private var scheduledDrains: [ScheduledDrain] = []
    private(set) var delays: [TimeInterval] = []

    func schedule(
        delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> WorkspaceTerminalFontSizeCoordinator.DrainCancellation {
        let index = scheduledDrains.count
        delays.append(delay)
        scheduledDrains.append(ScheduledDrain(action: action))
        return { [weak self] in
            self?.scheduledDrains[index].isCancelled = true
        }
    }

    func fire(at index: Int) {
        guard scheduledDrains.indices.contains(index),
              !scheduledDrains[index].isCancelled else {
            return
        }
        scheduledDrains[index].action()
    }
}
