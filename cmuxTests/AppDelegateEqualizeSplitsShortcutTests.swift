import AppKit
import Bonsplit
import CmuxFoundation
import CmuxRemoteSession
import CmuxTerminalCore
import Testing
@testable import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func testComment(
    _ message: @autoclosure () -> String
) -> Comment? {
    let value = message()
    return value.isEmpty ? nil : Comment(rawValue: value)
}

private func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file _: StaticString = #filePath,
    line _: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(
            value1 == value2,
            testComment(message()),
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertEqual<T: FloatingPoint>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    accuracy: T,
    _ message: @autoclosure () -> String = "",
    file _: StaticString = #filePath,
    line _: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(
            abs(value1 - value2) <= accuracy,
            testComment(message()),
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNotEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file _: StaticString = #filePath,
    line _: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(
            value1 != value2,
            testComment(message()),
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNotEqual<T: FloatingPoint>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    accuracy: T,
    _ message: @autoclosure () -> String = "",
    file _: StaticString = #filePath,
    line _: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(
            abs(value1 - value2) > accuracy,
            testComment(message()),
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file _: StaticString = #filePath,
    line _: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(
            try expression(),
            testComment(message()),
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file _: StaticString = #filePath,
    line _: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(
            try !expression(),
            testComment(message()),
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file _: StaticString = #filePath,
    line _: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(
            try expression() == nil,
            testComment(message()),
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNotNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file _: StaticString = #filePath,
    line _: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(
            try expression() != nil,
            testComment(message()),
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertGreaterThan<T: Comparable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file _: StaticString = #filePath,
    line _: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(
            try expression1() > expression2(),
            testComment(message()),
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertGreaterThanOrEqual<T: Comparable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file _: StaticString = #filePath,
    line _: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(
            try expression1() >= expression2(),
            testComment(message()),
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertLessThan<T: Comparable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file _: StaticString = #filePath,
    line _: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(
            try expression1() < expression2(),
            testComment(message()),
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertLessThanOrEqual<T: Comparable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file _: StaticString = #filePath,
    line _: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(
            try expression1() <= expression2(),
            testComment(message()),
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file _: StaticString = #filePath,
    line _: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
    let value = try expression()
    return try #require(
        value,
        testComment(message()),
        sourceLocation: sourceLocation
    )
}

private func XCTFail(
    _ message: @autoclosure () -> String = "",
    file _: StaticString = #filePath,
    line _: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    Issue.record(
        Comment(rawValue: message()),
        sourceLocation: sourceLocation
    )
}

private final class TestExpectation: @unchecked Sendable {
    let description: String
    private let condition = NSCondition()
    private var fulfillmentCount = 0
    private var expectedCount = 1

    init(description: String) {
        self.description = description
    }

    var expectedFulfillmentCount: Int {
        get {
            condition.withLock { expectedCount }
        }
        set {
            condition.withLock {
                precondition(newValue > 0)
                expectedCount = newValue
            }
        }
    }

    var isFulfilled: Bool {
        condition.withLock {
            fulfillmentCount >= expectedCount
        }
    }

    func fulfill() {
        condition.withLock {
            fulfillmentCount += 1
            condition.broadcast()
        }
    }
}

private func expectation(
    description: String
) -> TestExpectation {
    TestExpectation(description: description)
}

@MainActor
private func wait(
    for expectations: [TestExpectation],
    timeout: TimeInterval
) {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while expectations.contains(where: { !$0.isFulfilled }),
          Date() < deadline {
        RunLoop.main.run(
            mode: .default,
            before: min(
                deadline,
                Date(timeIntervalSinceNow: 0.01)
            )
        )
    }
    for expectation in expectations
    where !expectation.isFulfilled {
        XCTFail(
            "Timed out waiting for \(expectation.description)"
        )
    }
}

@MainActor
private func waitWhileSuspended(
    for expectations: [TestExpectation],
    timeout: TimeInterval
) async {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while expectations.contains(where: { !$0.isFulfilled }),
          Date() < deadline {
        await Task.yield()
        try? await Task<Never, Never>.sleep(
            nanoseconds: 1_000_000
        )
    }
    for expectation in expectations
    where !expectation.isFulfilled {
        XCTFail(
            "Timed out waiting for \(expectation.description)"
        )
    }
}

@MainActor
private extension TabManager {
    @discardableResult
    func requiredAddTabForTesting(
        select: Bool = true,
        eagerLoadTerminal: Bool = false
    ) -> Workspace {
        guard let workspace = addTab(
            select: select,
            eagerLoadTerminal: eagerLoadTerminal
        ) else {
            preconditionFailure(
                "Test fixture cannot add a workspace to a finalized manager"
            )
        }
        return workspace
    }
}

@Suite(.serialized)
@MainActor
final class AppDelegateEqualizeSplitsShortcutTests {
    @Test
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

    @Test
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

    @Test
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

    @Test
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

    @Test
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
            appDelegate.flushPendingWorkspaceTerminalFontSizeChangesForVerification()
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

    @Test
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
        XCTAssertEqual(coordinator.pendingRequestCountForVerification, 1)
#endif

        scheduler.fire(at: 0)
        XCTAssertEqual(
            panel.surface.fontSizeLineageSnapshot()?.basePoints,
            18
        )
    }

    @Test
    func testWorkspaceTerminalFontSizeDrainScheduleContractIsOneShotAndCancellable()
        async {
        var firedCount = 0
        let fired = expectation(
            description: "default drain schedule fires"
        )
        let completedCancellation =
            WorkspaceTerminalFontSizeCoordinator
                .scheduleDefaultDrain(after: 0) {
                    firedCount += 1
                    fired.fulfill()
                }

        await waitWhileSuspended(for: [fired], timeout: 1)
        completedCancellation()
        completedCancellation()
        XCTAssertEqual(firedCount, 1)

        var cancelledFireCount = 0
        // Drive cancellation through the coordinator's injected scheduler
        // instead of waiting for a real deadline.
        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        let pendingCancellation = scheduler.schedule(
            delay: 0.05
        ) {
            cancelledFireCount += 1
        }
        pendingCancellation()
        scheduler.fire(at: 0)
        XCTAssertEqual(cancelledFireCount, 0)
    }

    @Test
    func testGhosttyConfigDoesNotRetainWorkspaceFontIncreaseEqualizeFallback() {
        // cmux owns Cmd+Ctrl+= through KeyboardShortcutSettings. Ghostty's
        // built-in super+ctrl+= fallback must be unbound so clearing the cmux
        // shortcut releases the key to the terminal.
        guard let ghosttyConfig = GhosttyApp.shared.config else {
            XCTFail("Expected loaded Ghostty config")
            return
        }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = 24
        keyEvent.mods = ghostty_input_mods_e(
            rawValue:
                GHOSTTY_MODS_SUPER.rawValue
                | GHOSTTY_MODS_CTRL.rawValue
        )
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 61
        keyEvent.composing = false
        let isBinding = "=".withCString { pointer in
            keyEvent.text = pointer
            return ghostty_config_key_is_binding(
                ghosttyConfig,
                keyEvent
            )
        }

        XCTAssertFalse(
            isBinding,
            "Ghostty must not retain its Cmd+Ctrl+= equalize_splits fallback"
        )
    }

    @Test
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
            appDelegate.flushPendingWorkspaceTerminalFontSizeChangesForVerification()
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEvent))
            XCTAssertEqual(
                appDelegate.pendingWorkspaceTerminalFontSizeChangeCountForVerification,
                0
            )
#else
            XCTFail("Workspace font-size coalescer hooks are only available in DEBUG")
#endif
        }
    }

    @Test
    func testWorkspaceTerminalFontSizeResetRepeatDoesNotAcceptTerminalInput() {
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
                  let panelId = workspace.focusedPanelId,
                  let panel = workspace.terminalPanel(for: panelId),
                  let repeatedEvent = makeKeyDownEvent(
                    key: "0",
                    modifiers: [.command, .control],
                    keyCode: 29,
                    windowNumber: window.windowNumber,
                    isARepeat: true
                  ) else {
                XCTFail("Expected a terminal and repeated Cmd+Ctrl+0 event")
                return
            }

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            XCTAssertTrue(window.makeFirstResponder(panel.hostedView.surfaceView))
            var acceptedInputCount = 0
            let previousOnExplicitInput = panel.surface.onExplicitInput
            panel.surface.onExplicitInput = {
                acceptedInputCount += 1
                previousOnExplicitInput?()
            }
            defer { panel.surface.onExplicitInput = previousOnExplicitInput }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEvent))
#else
            XCTFail("Workspace font-size shortcut hooks require DEBUG")
            return
#endif

            XCTAssertEqual(
                acceptedInputCount,
                0,
                "A consumed reset key-repeat must not masquerade as accepted terminal input"
            )
        }
    }

    @Test
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
            appDelegate.flushPendingWorkspaceTerminalFontSizeChangesForVerification()
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEvent))
            appDelegate.flushPendingWorkspaceTerminalFontSizeChangesForVerification()
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

    @Test
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
            appDelegate.flushPendingWorkspaceTerminalFontSizeChangesForVerification()
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEvent))
            appDelegate.flushPendingWorkspaceTerminalFontSizeChangesForVerification()
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
            appDelegate
                .drainAllPendingWorkspaceTerminalFontSizeChangesForVerification()
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

    @Test
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
            appDelegate.flushPendingWorkspaceTerminalFontSizeChangesForVerification()
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEvent))
            appDelegate.flushPendingWorkspaceTerminalFontSizeChangesForVerification()
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
            appDelegate
                .drainAllPendingWorkspaceTerminalFontSizeChangesForVerification()
#endif
            XCTAssertEqual(
                latePanel.surface.fontSizeLineageSnapshot()?.basePoints,
                19
            )
        }
    }

    @Test
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
                appDelegate.flushPendingWorkspaceTerminalFontSizeChangesForVerification()
                XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: increaseEvent))

                let secondWorkspace = manager.requiredAddTabForTesting(select: true)
                XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: decreaseEvent))

                manager.selectTab(firstWorkspace)
                XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: increaseEvent))
                appDelegate
                    .drainAllPendingWorkspaceTerminalFontSizeChangesForVerification()
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

    @Test
    func testMatchedWorkspaceFontShortcutIsConsumedWhenQueueRejects() {
        withTemporaryShortcut(action: .decreaseWorkspaceTerminalFontSize) {
            guard let appDelegate = AppDelegate.shared else {
                XCTFail("Expected AppDelegate.shared")
                return
            }

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            guard let window = window(withId: windowId),
                  let manager =
                    appDelegate.tabManagerFor(windowId: windowId),
                  let context =
                    appDelegate.mainWindowContext(for: manager),
                  let event = makeKeyDownEvent(
                    key: "-",
                    modifiers: [.command, .control],
                    keyCode: 27,
                    windowNumber: window.windowNumber
                  ) else {
                XCTFail("Expected a window and Cmd+Ctrl+- event")
                return
            }

#if DEBUG
            context
                .debugWorkspaceTerminalFontSizeEnqueueResultOverride = false
            defer {
                context
                    .debugWorkspaceTerminalFontSizeEnqueueResultOverride = nil
            }
            XCTAssertTrue(
                appDelegate.debugHandleCustomShortcut(event: event),
                "A matched cmux shortcut must not leak into AppKit or Ghostty when its bounded queue rejects the request"
            )
#else
            XCTFail("Workspace font-size shortcut hooks require DEBUG")
#endif
        }
    }

    @Test
    func testDefaultTerminalDependenciesUseAppliedMagnificationDuringQueuedReload() {
        let defaults = UserDefaults.standard
        let originalValue =
            defaults.object(forKey: GlobalFontMagnification.percentKey)
        let appliedPercent =
            GhosttyApp.shared.appliedGlobalFontMagnificationPercent
        let queuedPercent =
            appliedPercent == GlobalFontMagnification.maximumPercent
            ? GlobalFontMagnification.minimumPercent
            : GlobalFontMagnification.maximumPercent
        defaults.set(
            queuedPercent,
            forKey: GlobalFontMagnification.percentKey
        )
        defer {
            if let originalValue {
                defaults.set(
                    originalValue,
                    forKey: GlobalFontMagnification.percentKey
                )
            } else {
                defaults.removeObject(
                    forKey: GlobalFontMagnification.percentKey
                )
            }
        }

        XCTAssertEqual(
            GlobalFontMagnification.storedPercent,
            queuedPercent
        )
        XCTAssertEqual(
            GhosttyApp.terminalSurfaceRuntimeDependencies
                .globalFontMagnificationPercent(),
            appliedPercent,
            "New surfaces must use the runtime-applied scale until the serialized config reload commits"
        )
    }

    @Test
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

    @Test
    func testWorkspaceTerminalFontSizeDiscoveryConstructionDoesNotScanPanels() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected an initial workspace")
            return
        }
        for _ in 0..<64 {
            let panel = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            workspace.panels[panel.id] = panel
        }

        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        var applyAttemptCount = 0
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: scheduler.schedule(delay:action:),
            applyChange: { _, _, _, _ in
                applyAttemptCount += 1
                return .alreadySatisfied
            }
        )
        defer { coordinator.cancelAll() }

        XCTAssertTrue(
            coordinator.enqueue(
                .relative([-1]),
                workspaceId: workspace.id,
                deferFlush: true
            )
        )

#if DEBUG
        coordinator.flushOneDrainForVerification()
        XCTAssertEqual(
            coordinator.debugLastPanelDiscoveryConstructionVisitCount,
            0,
            "Activating a request must not snapshot or scan its owner's panel dictionaries before the visit budget"
        )
        XCTAssertLessThanOrEqual(
            applyAttemptCount,
            WorkspaceTerminalFontSizeDrainBudget
                .maximumPanelVisitsPerDrain
        )
#else
        XCTFail("Workspace font-size discovery hooks require DEBUG")
#endif
    }

    @Test
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

    @Test
    func testPendingWorkspaceTerminalFontSizeChangeBoundsAlternatingWorkspaceStorage() {
        let manager = TabManager()
        guard let firstWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected an initial workspace")
            return
        }
        let secondWorkspace = manager.requiredAddTabForTesting(select: false)
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
            coordinator.pendingRequestCountForVerification,
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

    @Test
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

    @Test
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
        coordinator.flushOneDrainForVerification()
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
        coordinator.drainAllForVerification()
#endif

        XCTAssertTrue(
            testPanels.allSatisfy {
                $0.surface.fontSizeLineageSnapshot()?.basePoints == 19
            },
            "An in-flight request must follow the workspace object into its destination manager"
        )
    }

    @Test
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
        sourceCoordinator.flushOneDrainForVerification()
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
        destinationCoordinator.drainAllForVerification()
        sourceCoordinator.drainAllForVerification()
#endif

        XCTAssertTrue(
            testPanels.allSatisfy {
                $0.surface.fontSizeLineageSnapshot()?.basePoints == minimum
            },
            "A destination shortcut must run after the source window's older request"
        )
    }

    @Test
    func testCrossWindowTerminalTransferSerializesDestinationShortcut() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let sourceWorkspace = sourceManager.selectedWorkspace,
              let sourcePane =
                sourceWorkspace.bonsplitController.focusedPaneId,
              let destinationWorkspace =
                destinationManager.selectedWorkspace,
              let destinationPane =
                destinationWorkspace.bonsplitController
                    .focusedPaneId else {
            XCTFail("Expected source and destination panes")
            return
        }
        let minimum =
            TerminalFontSizePolicy.minimumRuntimePoints
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(
            minimum,
            isExplicitOverride: true
        )
        let movedPanel = TerminalPanel(
            workspaceId: sourceWorkspace.id,
            configTemplate: template,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        guard sourceWorkspace.attachDetachedSurface(
            makeDormantTerminalTransfer(
                panel: movedPanel,
                sourceWorkspaceId: sourceWorkspace.id
            ),
            inPane: sourcePane,
            focus: false
        ) != nil else {
            XCTFail("Expected a movable source terminal")
            return
        }

        let arbiter =
            WorkspaceTerminalFontSizeCoordinator.Arbiter()
        let sourceCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: sourceManager,
                arbiter: arbiter,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:)
            )
        let destinationCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: destinationManager,
                arbiter: arbiter,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:)
            )
        defer {
            sourceCoordinator.cancelAll()
            destinationCoordinator.cancelAll()
        }

        XCTAssertTrue(
            sourceCoordinator.enqueue(
                .relative([1]),
                workspaceId: sourceWorkspace.id,
                deferFlush: true
            )
        )
        guard let detached = sourceWorkspace.detachSurface(
            panelId: movedPanel.id
        ),
        destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        ) != nil else {
            XCTFail("Expected an unvisited cross-window terminal")
            return
        }

        XCTAssertTrue(
            destinationCoordinator.enqueue(
                .relative([-1]),
                workspaceId: destinationWorkspace.id,
                deferFlush: false
            )
        )
#if DEBUG
        destinationCoordinator.drainAllForVerification()
        sourceCoordinator.drainAllForVerification()
        destinationCoordinator.drainAllForVerification()
#endif

        XCTAssertEqual(
            movedPanel.surface.fontSizeLineageSnapshot()?
                .basePoints,
            minimum,
            "The source increase must precede the destination decrease at the native minimum"
        )
    }

    @Test
    func testSourceWindowClosePreservesTransferredTerminalWork() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let sourceWorkspace = sourceManager.selectedWorkspace,
              let sourcePane =
                sourceWorkspace.bonsplitController.focusedPaneId,
              let destinationWorkspace =
                destinationManager.selectedWorkspace,
              let destinationPane =
                destinationWorkspace.bonsplitController
                    .focusedPaneId else {
            XCTFail("Expected source and destination panes")
            return
        }
        let minimum =
            TerminalFontSizePolicy.minimumRuntimePoints
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(
            minimum,
            isExplicitOverride: true
        )
        let movedPanel = TerminalPanel(
            workspaceId: sourceWorkspace.id,
            configTemplate: template,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        guard sourceWorkspace.attachDetachedSurface(
            makeDormantTerminalTransfer(
                panel: movedPanel,
                sourceWorkspaceId: sourceWorkspace.id
            ),
            inPane: sourcePane,
            focus: false
        ) != nil else {
            XCTFail("Expected a movable source terminal")
            return
        }

        let arbiter =
            WorkspaceTerminalFontSizeCoordinator.Arbiter()
        let sourceCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: sourceManager,
                arbiter: arbiter,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:)
            )
        let destinationCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: destinationManager,
                arbiter: arbiter,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:)
            )
        defer {
            sourceCoordinator.cancelAll()
            destinationCoordinator.cancelAll()
        }

        XCTAssertTrue(
            sourceCoordinator.enqueue(
                .relative([1]),
                workspaceId: sourceWorkspace.id,
                deferFlush: true
            )
        )
        guard let detached = sourceWorkspace.detachSurface(
            panelId: movedPanel.id
        ),
        destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        ) != nil else {
            XCTFail("Expected an unvisited cross-window terminal")
            return
        }

        sourceCoordinator.cancelWindowOwnedWork()
#if DEBUG
        sourceCoordinator.drainAllForVerification()
#endif

        XCTAssertEqual(
            movedPanel.surface.fontSizeLineageSnapshot()?
                .basePoints,
            minimum + 1,
            "Closing the source window must not cancel accepted work carried by a moved terminal"
        )
    }

    @Test
    func testSourceWindowCloseCancelsLaterRequestBehindTransferredWork() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let sourceWorkspace = sourceManager.selectedWorkspace,
              let sourcePane =
                sourceWorkspace.bonsplitController.focusedPaneId,
              let destinationWorkspace =
                destinationManager.selectedWorkspace,
              let destinationPane =
                destinationWorkspace.bonsplitController
                    .focusedPaneId else {
            XCTFail("Expected source and destination panes")
            return
        }
        let minimum =
            TerminalFontSizePolicy.minimumRuntimePoints
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(
            minimum,
            isExplicitOverride: true
        )
        let movedPanel = TerminalPanel(
            workspaceId: sourceWorkspace.id,
            configTemplate: template,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        guard sourceWorkspace.attachDetachedSurface(
            makeDormantTerminalTransfer(
                panel: movedPanel,
                sourceWorkspaceId: sourceWorkspace.id
            ),
            inPane: sourcePane,
            focus: false
        ) != nil else {
            XCTFail("Expected a movable source terminal")
            return
        }

        var allowMovedPanelMutation = false
        var movedPanelChanges:
            [WorkspaceTerminalFontSizeChange] = []
        let coordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: sourceManager,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:),
                applyChange: {
                    change,
                    candidate,
                    configuredRuntimePoints,
                    magnificationPercent in
                    guard candidate === movedPanel else {
                        return .alreadySatisfied
                    }
                    movedPanelChanges.append(change)
                    guard allowMovedPanelMutation else {
                        return .failed
                    }
                    return cmuxApplyTerminalFontSizeChange(
                        change,
                        to: candidate,
                        configuredRuntimePoints:
                            configuredRuntimePoints,
                        magnificationPercent:
                            magnificationPercent
                    )
                }
            )
        defer { coordinator.cancelAll() }

        XCTAssertTrue(
            coordinator.enqueue(
                .relative([1]),
                workspaceId: sourceWorkspace.id,
                deferFlush: true
            )
        )
        guard let detached = sourceWorkspace.detachSurface(
            panelId: movedPanel.id
        ),
        destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        ) != nil else {
            XCTFail("Expected an unvisited cross-window terminal")
            return
        }
        XCTAssertTrue(
            movedPanelChanges.isEmpty,
            "The transferred terminal must remain queued before teardown"
        )

        XCTAssertTrue(
            coordinator.enqueue(
                .relative([1]),
                workspaceId: sourceWorkspace.id,
                deferFlush: true
            )
        )
        coordinator.cancelWindowOwnedWork()
#if DEBUG
        XCTAssertEqual(coordinator.outstandingRequestCountForVerification, 1)
        allowMovedPanelMutation = true
        coordinator.drainAllForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        XCTAssertEqual(
            movedPanelChanges,
            [.relative([1])],
            "Closing the source window must cancel the later request without discarding the staged transfer"
        )
        XCTAssertEqual(
            movedPanel.surface.fontSizeLineageSnapshot()?
                .basePoints,
            minimum + 1
        )
    }

    @Test
    func testClosedWindowHistoryProjectsAcceptedMultiTurnFontChangeWithoutDraining() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        ClosedItemHistoryStore.shared.removeAll()

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let windowId =
            appDelegate.registerMainWindowContextForTesting(
                tabManager: manager
            )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(
                windowId: windowId
            )
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
            ClosedItemHistoryStore.shared.removeAll()
            AppDelegate.shared = previousAppDelegate
        }

        for _ in 0..<20 {
            let panel = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            workspace.panels[panel.id] = panel
        }
        let terminalPanels =
            workspace.panels.values.compactMap {
                $0 as? TerminalPanel
            }
        for panel in terminalPanels {
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
        }

        let context = try XCTUnwrap(
            appDelegate.mainWindowContexts.values.first {
                $0.windowId == windowId
            }
        )
        XCTAssertTrue(
            context.workspaceTerminalFontSizeCoordinator.enqueue(
                .relative([-1]),
                workspaceId: workspace.id,
                deferFlush: true
            )
        )
#if DEBUG
        context.workspaceTerminalFontSizeCoordinator
            .flushOneDrainForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        let adjustedBeforeSnapshot = terminalPanels.count {
            $0.surface.fontSizeLineageSnapshot()?.basePoints == 19
        }
        XCTAssertGreaterThan(adjustedBeforeSnapshot, 0)
        XCTAssertLessThan(
            adjustedBeforeSnapshot,
            terminalPanels.count,
            "The first bounded drain must leave accepted work pending"
        )

        appDelegate.recordClosedWindowHistoryForTesting(
            windowId: windowId
        )
#if DEBUG
        XCTAssertEqual(
            terminalPanels.count {
                $0.surface.fontSizeLineageSnapshot()?.basePoints == 19
            },
            adjustedBeforeSnapshot,
            "Snapshotting must not synchronously rebuild the remaining terminals"
        )
        XCTAssertGreaterThan(
            context.workspaceTerminalFontSizeCoordinator
                .outstandingRequestCountForVerification,
            0,
            "The bounded mutation queue must keep draining normally after snapshotting"
        )
#endif
        let historyItem = try XCTUnwrap(
            ClosedItemHistoryStore.shared.menuSnapshot().items.first
        )
        let historyRecord = try XCTUnwrap(
            ClosedItemHistoryStore.shared.removeRecord(
                id: historyItem.id
            )?.record
        )
        guard case .window(let closedWindow) =
                historyRecord.entry else {
            XCTFail("Expected closed-window history")
            return
        }
        let persistedFontSizes =
            closedWindow.snapshot.tabManager.workspaces
                .flatMap(\.panels)
                .compactMap(\.terminal?.fontSize)

        XCTAssertEqual(
            persistedFontSizes.count,
            terminalPanels.count
        )
        XCTAssertTrue(
            persistedFontSizes.allSatisfy {
                abs($0 - 19) < 0.000_1
            },
            "Window close must settle every accepted font change before recording its restorable snapshot"
        )
    }

    @Test
    func testWorkspaceSnapshotProjectsAcceptedMultiTurnFontChangeWithoutDraining() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        for _ in 0..<20 {
            let panel = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            workspace.panels[panel.id] = panel
        }
        let terminalPanels =
            workspace.panels.values.compactMap {
                $0 as? TerminalPanel
            }
        for panel in terminalPanels {
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
        }

        let coordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: manager,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:)
            )
        defer { coordinator.cancelAll() }
        XCTAssertTrue(
            coordinator.enqueue(
                .relative([-1]),
                workspaceId: workspace.id,
                deferFlush: true
            )
        )
#if DEBUG
        coordinator.flushOneDrainForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        let adjustedBeforeSnapshot = terminalPanels.count {
            $0.surface.fontSizeLineageSnapshot()?.basePoints == 19
        }
        XCTAssertGreaterThan(adjustedBeforeSnapshot, 0)
        XCTAssertLessThan(
            adjustedBeforeSnapshot,
            terminalPanels.count
        )

        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty
        )
        let persistedFontSizes =
            snapshot.panels.compactMap(\.terminal?.fontSize)
        XCTAssertEqual(
            persistedFontSizes.count,
            terminalPanels.count
        )
        XCTAssertTrue(
            persistedFontSizes.allSatisfy {
                abs($0 - 19) < 0.000_1
            },
            "Every restorable workspace snapshot must project accepted font-size intent"
        )
        XCTAssertEqual(
            terminalPanels.count {
                $0.surface.fontSizeLineageSnapshot()?.basePoints == 19
            },
            adjustedBeforeSnapshot,
            "Workspace snapshotting must not bypass the per-turn native mutation budget"
        )
#if DEBUG
        XCTAssertGreaterThan(
            coordinator.outstandingRequestCountForVerification,
            0
        )
#endif
    }

    @Test
    func testWorkspaceSnapshotProjectsPendingResetOrdering() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let terminalPanels =
            workspace.panels.values.compactMap {
                $0 as? TerminalPanel
            }
        XCTAssertFalse(terminalPanels.isEmpty)
        for panel in terminalPanels {
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
        }

        let coordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: manager,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:),
                configurationSnapshot: {
                    WorkspaceTerminalFontConfigurationSnapshot(
                        configuredRuntimePoints: 12,
                        magnificationPercent: 100
                    )
                }
            )
        defer { coordinator.cancelAll() }
        XCTAssertTrue(
            coordinator.enqueue(
                .relative([-1]),
                workspaceId: workspace.id,
                deferFlush: true
            )
        )
        XCTAssertTrue(
            coordinator.enqueue(
                .resetThen([]),
                workspaceId: workspace.id,
                deferFlush: true
            )
        )
        XCTAssertTrue(
            coordinator.enqueue(
                .relative([1]),
                workspaceId: workspace.id,
                deferFlush: true
            )
        )

        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty
        )
        XCTAssertTrue(
            snapshot.panels.compactMap(\.terminal).allSatisfy {
                $0.fontSize == 13
            },
            "Snapshot projection must preserve relative, reset, then relative ordering"
        )
        XCTAssertTrue(
            terminalPanels.allSatisfy {
                $0.surface.fontSizeLineageSnapshot()?
                    .basePoints == 20
            },
            "Snapshot projection must not apply pending native mutations"
        )
    }

    @Test
    func testWorkspaceSnapshotProjectsJoinDeferredBehindConfigurationBarrier() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(
            workspace.bonsplitController.focusedPaneId
        )
        let terminalPanels =
            workspace.panels.values.compactMap {
                $0 as? TerminalPanel
            }
        XCTAssertFalse(terminalPanels.isEmpty)
        for panel in terminalPanels {
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
        }

        let arbiter = WorkspaceTerminalFontSizeArbiter()
        let coordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: manager,
                arbiter: arbiter,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:)
            )
        defer { coordinator.cancelAll() }
        var finishConfigurationBarrier:
            (@MainActor () -> Void)?
        arbiter.performWhenFontSizeWorkIsIdle {
            finishConfigurationBarrier =
                arbiter.extendCurrentFontSizeWorkIdleBarrier()
        }
        defer { finishConfigurationBarrier?() }
        arbiter
            .setCurrentFontSizeWorkIdleBarrierProjectionConfiguration(
                WorkspaceTerminalFontConfigurationSnapshot(
                    configuredRuntimePoints: 12,
                    magnificationPercent: 100
                )
            )

        XCTAssertTrue(
            coordinator.enqueue(
                .relative([-1]),
                workspaceId: workspace.id,
                deferFlush: true
            )
        )
        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty
        )
        XCTAssertTrue(
            snapshot.panels.compactMap(\.terminal).allSatisfy {
                $0.fontSize == 19
            },
            "Snapshot projection must include accepted joins that cannot promote yet"
        )
        XCTAssertTrue(
            terminalPanels.allSatisfy {
                $0.surface.fontSizeLineageSnapshot()?
                    .basePoints == 20
            }
        )
        let projectedTerminal = try XCTUnwrap(
            snapshot.panels.compactMap(\.terminal).first
        )
        XCTAssertFalse(
            projectedTerminal.fontSizeChangeTokens?.isEmpty
                ?? true
        )
        let restoredPanel = try XCTUnwrap(
            workspace.newTerminalSurface(
                inPane: pane,
                focus: false,
                runtimeSpawnPolicy: .pacedSessionRestore,
                terminalFontSizeCreationPolicy:
                    .sessionRestore(
                        overrideBasePoints:
                            projectedTerminal.fontSize,
                        representedChangeTokens: Set(
                            projectedTerminal
                                .fontSizeChangeTokens
                                ?? []
                        )
                )
            )
        )
        _ = restoredPanel.surface.runtimeCreationConfigTemplate()
        let resnapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty
        )
        let restoredTerminal = try XCTUnwrap(
            resnapshot.panels.first {
                $0.id == restoredPanel.id
            }?.terminal
        )
        XCTAssertEqual(
            restoredTerminal.fontSize,
            19,
            "A second snapshot before promotion must not project the deferred change twice"
        )
        XCTAssertFalse(
            restoredTerminal.fontSizeChangeTokens?.isEmpty
                ?? true,
            "Runtime creation must retain snapshot-visible deferred provenance"
        )

        finishConfigurationBarrier?()
        finishConfigurationBarrier = nil
#if DEBUG
        coordinator.drainAllForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        XCTAssertEqual(
            restoredPanel.surface
                .fontSizeLineageSnapshot()?
                .basePoints,
            19,
            "Promoting a deferred join must not replay its projected change on a restored terminal"
        )
    }

    @Test
    func testWorkspaceSnapshotWithholdsPostBarrierChangeUntilExecutionConfigurationIsKnown() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let terminalPanels =
            workspace.panels.values.compactMap {
                $0 as? TerminalPanel
            }
        XCTAssertFalse(terminalPanels.isEmpty)
        for panel in terminalPanels {
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 15,
                    isExplicitOverride: true
                )
            )
        }

        let arbiter = WorkspaceTerminalFontSizeArbiter()
        var executionConfiguration =
            WorkspaceTerminalFontConfigurationSnapshot(
                configuredRuntimePoints: 15,
                magnificationPercent: 100
            )
        let coordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: manager,
                arbiter: arbiter,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:),
                configurationSnapshot: {
                    executionConfiguration
                }
            )
        defer { coordinator.cancelAll() }
        var finishConfigurationBarrier:
            (@MainActor () -> Void)?
        arbiter.performWhenFontSizeWorkIsIdle {
            finishConfigurationBarrier =
                arbiter.extendCurrentFontSizeWorkIdleBarrier()
        }
        defer { finishConfigurationBarrier?() }

        XCTAssertTrue(
            coordinator.enqueue(
                .relative([1]),
                workspaceId: workspace.id,
                deferFlush: true
            )
        )
        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty
        )
        XCTAssertTrue(
            snapshot.panels.compactMap(\.terminal).allSatisfy {
                $0.fontSize == 15
            },
            "Projection must wait rather than guess with the pre-reload configuration"
        )

        let targetConfiguration =
            WorkspaceTerminalFontConfigurationSnapshot(
                configuredRuntimePoints: 30,
                magnificationPercent: 200
            )
        arbiter
            .setCurrentFontSizeWorkIdleBarrierProjectionConfiguration(
                targetConfiguration
            )
        let targetSnapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty
        )
        XCTAssertTrue(
            targetSnapshot.panels.compactMap(\.terminal).allSatisfy {
                $0.fontSize == 15.5
            },
            "Projection must use the parsed configuration that will execute the request"
        )

        executionConfiguration = targetConfiguration
        finishConfigurationBarrier?()
        finishConfigurationBarrier = nil
#if DEBUG
        coordinator.drainAllForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        XCTAssertTrue(
            terminalPanels.allSatisfy {
                $0.surface.fontSizeLineageSnapshot()?
                    .basePoints == 15.5
            }
        )
    }

    @Test
    func testClosedPanelHistoryProjectsPendingFontChange() throws {
        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(
            workspace.bonsplitController.focusedPaneId
        )
        for _ in 0..<12 {
            _ = workspace.newTerminalSurface(
                inPane: pane,
                focus: false
            )
        }
        let terminalPanels =
            workspace.panels.values.compactMap {
                $0 as? TerminalPanel
            }
        for panel in terminalPanels {
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
        }

        let coordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: manager,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:)
            )
        defer { coordinator.cancelAll() }
        XCTAssertTrue(
            coordinator.enqueue(
                .relative([-1]),
                workspaceId: workspace.id,
                deferFlush: true
            )
        )
#if DEBUG
        coordinator.flushOneDrainForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        let pendingPanel = try XCTUnwrap(
            terminalPanels.first {
                $0.surface.fontSizeLineageSnapshot()?
                    .basePoints == 20
            }
        )

        workspace.markCloseHistoryEligible(
            panelId: pendingPanel.id
        )
        XCTAssertTrue(
            workspace.closePanel(
                pendingPanel.id,
                force: true
            )
        )
        let historyItem = try XCTUnwrap(
            ClosedItemHistoryStore.shared
                .menuSnapshot().items.first
        )
        let historyRecord = try XCTUnwrap(
            ClosedItemHistoryStore.shared.removeRecord(
                id: historyItem.id
            )?.record
        )
        guard case .panel(let closedPanel) =
                historyRecord.entry else {
            XCTFail("Expected closed-panel history")
            return
        }
        XCTAssertEqual(
            closedPanel.snapshot.terminal?.fontSize,
            19,
            "Closed-panel history must project the accepted workspace mutation"
        )
        let reopenedPanelId = try XCTUnwrap(
            workspace.restoreClosedPanel(closedPanel)
        )
        let reopenedPanel = try XCTUnwrap(
            workspace.terminalPanel(for: reopenedPanelId)
        )
#if DEBUG
        coordinator.drainAllForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        XCTAssertEqual(
            reopenedPanel.surface
                .fontSizeLineageSnapshot()?
                .basePoints,
            19,
            "Reopening a projected close-history snapshot must not replay the pending mutation"
        )
    }

    @Test
    func testDestinationSnapshotProjectsTransferredPendingFontChange() throws {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        let sourceWorkspace =
            try XCTUnwrap(sourceManager.selectedWorkspace)
        let sourcePane = try XCTUnwrap(
            sourceWorkspace.bonsplitController.focusedPaneId
        )
        let destinationWorkspace =
            try XCTUnwrap(destinationManager.selectedWorkspace)
        let destinationPane = try XCTUnwrap(
            destinationWorkspace.bonsplitController
                .focusedPaneId
        )

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
        XCTAssertNotNil(
            sourceWorkspace.attachDetachedSurface(
                makeDormantTerminalTransfer(
                    panel: panel,
                    sourceWorkspaceId: sourceWorkspace.id
                ),
                inPane: sourcePane,
                focus: false
            )
        )

        let coordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: sourceManager,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:),
                applyChange: { _, _, _, _ in .failed }
            )
        defer { coordinator.cancelAll() }
        XCTAssertTrue(
            coordinator.enqueue(
                .relative([-1]),
                workspaceId: sourceWorkspace.id,
                deferFlush: true
            )
        )
        let detached = try XCTUnwrap(
            sourceWorkspace.detachSurface(panelId: panel.id)
        )
        XCTAssertNotNil(
            destinationWorkspace.attachDetachedSurface(
                detached,
                inPane: destinationPane,
                focus: false
            )
        )
        XCTAssertEqual(
            panel.surface.fontSizeLineageSnapshot()?.basePoints,
            20
        )

        let snapshot = destinationWorkspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty
        )
        let transferredSnapshot = try XCTUnwrap(
            snapshot.panels.first {
                $0.id == panel.id
            }
        )
        XCTAssertEqual(
            transferredSnapshot.terminal?.fontSize,
            19,
            "A destination snapshot must include a foreign coordinator's staged transfer"
        )
        XCTAssertEqual(
            panel.surface.fontSizeLineageSnapshot()?.basePoints,
            20,
            "Transfer projection must not retry the failed native mutation"
        )
    }

    @Test
    func testClosedWindowSnapshotDoesNotDrainAnotherWindowFontChange() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        ClosedItemHistoryStore.shared.removeAll()

        let closingManager = TabManager()
        let activeManager = TabManager()
        let closingWindowId =
            appDelegate.registerMainWindowContextForTesting(
                tabManager: closingManager
            )
        let activeWindowId =
            appDelegate.registerMainWindowContextForTesting(
                tabManager: activeManager
            )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(
                windowId: activeWindowId
            )
            appDelegate.unregisterMainWindowContextForTesting(
                windowId: closingWindowId
            )
            appDelegate.forgetRecoverableMainWindowRoute(
                windowId: activeWindowId
            )
            appDelegate.forgetRecoverableMainWindowRoute(
                windowId: closingWindowId
            )
            ClosedItemHistoryStore.shared.removeAll()
            AppDelegate.shared = previousAppDelegate
        }

        let activeWorkspace =
            try XCTUnwrap(activeManager.selectedWorkspace)
        for _ in 0..<20 {
            let panel = TerminalPanel(
                workspaceId: activeWorkspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            activeWorkspace.panels[panel.id] = panel
        }
        let activePanels =
            activeWorkspace.panels.values.compactMap {
                $0 as? TerminalPanel
            }
        for panel in activePanels {
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
        }
        let activeContext = try XCTUnwrap(
            appDelegate.mainWindowContexts.values.first {
                $0.windowId == activeWindowId
            }
        )
        XCTAssertTrue(
            activeContext.workspaceTerminalFontSizeCoordinator
                .enqueue(
                    .relative([-1]),
                    workspaceId: activeWorkspace.id,
                    deferFlush: true
                )
        )
#if DEBUG
        activeContext.workspaceTerminalFontSizeCoordinator
            .flushOneDrainForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        let adjustedBeforeClosingOtherWindow =
            activePanels.count {
                $0.surface.fontSizeLineageSnapshot()?.basePoints
                    == 19
            }
        XCTAssertGreaterThan(
            adjustedBeforeClosingOtherWindow,
            0
        )
        XCTAssertLessThan(
            adjustedBeforeClosingOtherWindow,
            activePanels.count
        )

        appDelegate.recordClosedWindowHistoryForTesting(
            windowId: closingWindowId
        )

        XCTAssertEqual(
            activePanels.count {
                $0.surface.fontSizeLineageSnapshot()?.basePoints
                    == 19
            },
            adjustedBeforeClosingOtherWindow,
            "Snapshotting one window must not run native font mutations in another"
        )
#if DEBUG
        XCTAssertGreaterThan(
            activeContext.workspaceTerminalFontSizeCoordinator
                .outstandingRequestCountForVerification,
            0
        )
#endif
    }

    @Test
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
        sourceCoordinator.flushOneDrainForVerification()
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
        sourceCoordinator.drainAllForVerification()
        destinationCoordinator.drainAllForVerification()
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

    @Test
    func testForeignCoordinatorAssociatesPanelTransferWithEnteredDock() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let movedWorkspace = sourceManager.selectedWorkspace,
              let movedPane =
                movedWorkspace.bonsplitController.focusedPaneId,
              let destinationWorkspace =
                destinationManager.selectedWorkspace else {
            XCTFail("Expected source and destination workspace panes")
            return
        }

        let movedPanel = TerminalPanel(
            workspaceId: movedWorkspace.id,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        movedPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )
        guard movedWorkspace.attachDetachedSurface(
            makeDormantTerminalTransfer(
                panel: movedPanel,
                sourceWorkspaceId: movedWorkspace.id
            ),
            inPane: movedPane,
            focus: false
        ) != nil else {
            XCTFail("Expected a movable source terminal")
            return
        }

        let sourceDock = sourceManager.makeWindowDockStore(
            windowId: UUID()
        )
        let destinationDock =
            destinationManager.makeWindowDockStore(
                windowId: UUID()
            )
        guard let destinationDockPane =
                destinationDock.bonsplitController.focusedPaneId else {
            XCTFail("Expected a destination Dock pane")
            return
        }
        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        let sourceCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: sourceManager,
                arbiter: arbiter,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:),
                applyChange: {
                    _,
                    panel,
                    _,
                    _ in
                    panel === movedPanel
                        ? .failed
                        : .alreadySatisfied
                }
            )
        let destinationCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: destinationManager,
                arbiter: arbiter,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:)
            )
        sourceCoordinator.attachWindowDock(sourceDock)
        destinationCoordinator.attachWindowDock(destinationDock)
        defer {
            sourceCoordinator.cancelAll()
            destinationCoordinator.cancelAll()
            sourceDock.closeAllPanels()
            destinationDock.closeAllPanels()
        }

        XCTAssertTrue(
            sourceCoordinator.enqueue(
                .relative([-1]),
                workspaceId: movedWorkspace.id,
                deferFlush: true
            )
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
        XCTAssertTrue(
            destinationCoordinator.enqueue(
                .relative([-1]),
                workspaceId: movedWorkspace.id,
                deferFlush: true
            )
        )
        XCTAssertTrue(
            destinationDock.terminalFontSizeChangeCoordinator
                === sourceCoordinator,
            "The foreign workspace owner must temporarily own the destination Dock request"
        )

        guard let detachedPanel = movedWorkspace.detachSurface(
            panelId: movedPanel.id
        ),
        destinationDock.attachDetachedSurface(
            detachedPanel,
            inPane: destinationDockPane,
            focus: false
        ) != nil else {
            XCTFail("Expected the terminal to enter the destination Dock")
            return
        }
        guard let panelTransfer = movedPanel.fontSizePanelTransfer else {
            XCTFail("Expected an active cross-container transfer")
            return
        }
        XCTAssertTrue(panelTransfer.isActive)

        XCTAssertTrue(
            arbiter.hasPanelTransfer(
                targeting: destinationWorkspace,
                or: .init(destinationDock)
            ),
            "The active transfer must block new work targeting the Dock it actually entered"
        )
        XCTAssertFalse(
            arbiter.hasPanelTransfer(
                targeting: destinationWorkspace,
                or: .init(sourceDock)
            ),
            "A foreign coordinator must not reassign the transfer to its home Dock"
        )
    }

    @Test
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
        let sourceOtherWorkspace = sourceManager.requiredAddTabForTesting(select: false)
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
        sourceCoordinator.drainAllForVerification()
        destinationCoordinator.drainAllForVerification()
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

    @Test
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
        sourceCoordinator.flushOneDrainForVerification()
        destinationCoordinator.flushOneDrainForVerification()
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
        sourceCoordinator.drainAllForVerification()
        destinationCoordinator.drainAllForVerification()
        sourceCoordinator.drainAllForVerification()
#endif
        XCTAssertTrue(
            destinationDockPanels.allSatisfy {
                $0.surface.fontSizeLineageSnapshot()?.basePoints
                    == minimum
            },
            "The earlier Dock increase must finish before the later decrease"
        )
    }

    @Test
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
        sourceCoordinator.flushOneDrainForVerification()
        destinationCoordinator.flushOneDrainForVerification()
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
        sourceCoordinator.drainAllForVerification()
        destinationCoordinator.drainAllForVerification()
        sourceCoordinator.drainAllForVerification()
#endif
        XCTAssertTrue(
            destinationDockPanels.allSatisfy {
                $0.surface.fontSizeLineageSnapshot()?.basePoints
                    == minimum + 1
            },
            "A later event sharing the Dock must wait behind the deferred join"
        )
    }

    @Test
    func testParkedCrossWindowOwnersWakeAndBoundDeferredBacklog() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let movedWorkspace = sourceManager.selectedWorkspace,
              let destinationWorkspace =
                destinationManager.selectedWorkspace else {
            XCTFail("Expected source and destination workspaces")
            return
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
                basePoints: 20,
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

        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter(
            maximumDeferredCoordinatorJoinCount: 4
        )
        let sourceScheduler = ManualWorkspaceFontSizeDrainScheduler()
        let destinationScheduler =
            ManualWorkspaceFontSizeDrainScheduler()
        let sourceCoordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: sourceManager,
            arbiter: arbiter,
            schedule: sourceScheduler.schedule(delay:action:),
            applyChange: { _, _, _, _ in .failed }
        )
        let destinationCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: destinationManager,
                arbiter: arbiter,
                schedule: destinationScheduler.schedule(delay:action:),
                applyChange: { _, _, _, _ in .failed }
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
            .relative([-1]),
            workspaceId: movedWorkspace.id,
            deferFlush: true
        )
        destinationCoordinator.enqueue(
            .relative([-1]),
            workspaceId: destinationWorkspace.id,
            deferFlush: true
        )
#if DEBUG
        sourceCoordinator.flushOneDrainForVerification()
        destinationCoordinator.flushOneDrainForVerification()
        sourceScheduler.fire(at: 1)
        destinationScheduler.fire(at: 1)
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        guard let detached =
                sourceManager.detachWorkspace(
                    tabId: movedWorkspace.id
                ) else {
            XCTFail("Expected the source workspace to detach")
            return
        }
        destinationManager.attachWorkspace(detached, select: true)

        let sourceScheduleCount = sourceScheduler.delays.count
        let destinationScheduleCount =
            destinationScheduler.delays.count
        XCTAssertTrue(
            destinationCoordinator.enqueue(
                .relative([-1]),
                workspaceId: movedWorkspace.id,
                deferFlush: true
            )
        )

        XCTAssertGreaterThan(
            sourceScheduler.delays.count,
            sourceScheduleCount,
            "A deferred join must schedule its parked workspace owner"
        )
        XCTAssertGreaterThan(
            destinationScheduler.delays.count,
            destinationScheduleCount,
            "A deferred join must schedule its parked Dock owner"
        )

        var enqueueResults: [Bool] = []
        for index in 0..<12 {
            if index.isMultiple(of: 2) {
                enqueueResults.append(
                    destinationCoordinator.enqueue(
                        .relative([-1]),
                        workspaceId: movedWorkspace.id,
                        deferFlush: true
                    )
                )
            } else {
                enqueueResults.append(
                    sourceCoordinator.enqueue(
                        .relative([1]),
                        workspaceId: destinationWorkspace.id,
                        deferFlush: true
                    )
                )
            }
        }

        guard let deferredJoinCount = mirroredCollectionCount(
            named: "deferredCoordinatorJoins",
            in: arbiter
        ) else {
            XCTFail("Expected deferred coordinator join storage")
            return
        }
        XCTAssertLessThanOrEqual(
            deferredJoinCount,
            4,
            "Backpressure must bound retained deferred join storage"
        )
        XCTAssertTrue(enqueueResults.contains(true))
        XCTAssertTrue(
            enqueueResults.contains(false),
            "The caller must observe deferred-join backpressure"
        )
    }

    @Test
    func testParkedCoordinatorBackpressuresBoundedRequestLedger() {
        let manager = TabManager()
        guard let firstWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected an initial workspace")
            return
        }
        let secondWorkspace = manager.requiredAddTabForTesting(select: false)
        let thirdWorkspace = manager.requiredAddTabForTesting(select: false)
        let windowDock = manager.makeWindowDockStore(windowId: UUID())
        let dockPanel = TerminalPanel(
            workspaceId: windowDock.workspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        windowDock.panels[dockPanel.id] = dockPanel
        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        var dockApplyAttemptCount = 0
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            maximumOutstandingRequestCount: 4,
            schedule: scheduler.schedule(delay:action:),
            applyChange: { _, candidate, _, _ in
                guard candidate === dockPanel else {
                    return .alreadySatisfied
                }
                dockApplyAttemptCount += 1
                return .failed
            }
        )
        coordinator.attachWindowDock(windowDock)
        defer {
            coordinator.cancelAll()
            windowDock.closeAllPanels()
        }

        XCTAssertTrue(
            coordinator.enqueue(
                .relative([-1]),
                workspaceId: firstWorkspace.id,
                deferFlush: true
            )
        )
#if DEBUG
        coordinator.flushOneDrainForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        scheduler.fire(at: 1)
        XCTAssertEqual(dockApplyAttemptCount, 2)

        XCTAssertTrue(
            coordinator.enqueue(
                .relative([-1]),
                workspaceId: secondWorkspace.id,
                deferFlush: true
            )
        )
        XCTAssertTrue(
            coordinator.enqueue(
                .relative([1]),
                workspaceId: secondWorkspace.id,
                deferFlush: true
            ),
            "An event that adds no retained request may still coalesce at capacity"
        )
        let transferMarker = TerminalPanel(
            workspaceId: secondWorkspace.id,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        coordinator.terminalWillLeaveWorkspace(
            transferMarker,
            workspace: secondWorkspace
        )
        XCTAssertFalse(
            coordinator.enqueue(
                .relative([-1]),
                workspaceId: thirdWorkspace.id,
                deferFlush: true
            ),
            "The caller must observe sealed-ledger backpressure"
        )
#if DEBUG
        XCTAssertEqual(coordinator.outstandingRequestCountForVerification, 4)
#endif
    }

    @Test
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
        coordinator.flushOneDrainForVerification()
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
        coordinator.drainAllForVerification()
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

    @Test
    func testCrossWindowTransferredDescendantInheritsPendingSourceRequest() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let sourceWorkspace = sourceManager.selectedWorkspace,
              let sourcePane =
                sourceWorkspace.bonsplitController.focusedPaneId,
              let destinationWorkspace =
                destinationManager.selectedWorkspace,
              let destinationPane =
                destinationWorkspace.bonsplitController
                    .focusedPaneId else {
            XCTFail("Expected source and destination workspace panes")
            return
        }

        let movedPanel = TerminalPanel(
            workspaceId: sourceWorkspace.id,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        movedPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: 20,
                isExplicitOverride: true
            )
        )
        guard sourceWorkspace.attachDetachedSurface(
            makeDormantTerminalTransfer(
                panel: movedPanel,
                sourceWorkspaceId: sourceWorkspace.id
            ),
            inPane: sourcePane,
            focus: false
        ) != nil else {
            XCTFail("Expected a movable source terminal")
            return
        }

        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        let sourceCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: sourceManager,
                arbiter: arbiter,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:)
            )
        defer { sourceCoordinator.cancelAll() }
        XCTAssertTrue(
            sourceCoordinator.enqueue(
                .relative([-1]),
                workspaceId: sourceWorkspace.id,
                deferFlush: true
            )
        )

        guard let detached =
                sourceWorkspace.detachSurface(
                    panelId: movedPanel.id
                ),
              destinationWorkspace.attachDetachedSurface(
                detached,
                inPane: destinationPane,
                focus: false
              ) != nil,
              let descendant =
                destinationWorkspace.newTerminalSplit(
                    from: movedPanel.id,
                    orientation: .horizontal,
                    focus: false
                ) else {
            XCTFail("Expected a moved terminal and descendant")
            return
        }
        XCTAssertEqual(
            descendant.surface.fontSizeLineageSnapshot()?
                .basePoints,
            19,
            "A descendant must inherit source work still pending on its moved parent"
        )

#if DEBUG
        sourceCoordinator.drainAllForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        XCTAssertEqual(
            movedPanel.surface.fontSizeLineageSnapshot()?
                .basePoints,
            19
        )
        XCTAssertEqual(
            descendant.surface.fontSizeLineageSnapshot()?
                .basePoints,
            19,
            "The source request must not replay on the projected descendant"
        )
    }

    @Test
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
        coordinator.flushOneDrainForVerification()
#endif
        guard let detached =
                sourceManager.detachWorkspace(tabId: workspace.id) else {
            XCTFail("Expected the source manager to detach the workspace")
            return
        }
        destinationManager.attachWorkspace(detached, select: true)

        sourceContext.teardownWindowDock()
#if DEBUG
        coordinator.drainAllForVerification()
#endif
        XCTAssertTrue(
            testPanels.allSatisfy {
                $0.surface.fontSizeLineageSnapshot()?.basePoints == 19
            },
            "Closing the source window must not cancel destination-owned work"
        )
    }

    @Test
    func testSourceWindowTeardownPreservesMovedWorkspaceDeferredBehindConfigurationBarrier() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let workspace = sourceManager.selectedWorkspace else {
            XCTFail("Expected a source workspace")
            return
        }
        let testPanels = workspace.panels.values.compactMap {
            $0 as? TerminalPanel
        }
        XCTAssertFalse(testPanels.isEmpty)
        for panel in testPanels {
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
        }

        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        let sourceCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: sourceManager,
                arbiter: arbiter,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:)
            )
        let destinationCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: destinationManager,
                arbiter: arbiter,
                schedule:
                    ManualWorkspaceFontSizeDrainScheduler()
                        .schedule(delay:action:)
            )
        defer {
            sourceCoordinator.cancelAll()
            destinationCoordinator.cancelAll()
        }

        var finishConfigurationBarrier:
            (@MainActor () -> Void)?
        arbiter.performWhenFontSizeWorkIsIdle {
            finishConfigurationBarrier =
                arbiter.extendCurrentFontSizeWorkIdleBarrier()
        }
        defer { finishConfigurationBarrier?() }
        arbiter
            .setCurrentFontSizeWorkIdleBarrierProjectionConfiguration(
                WorkspaceTerminalFontConfigurationSnapshot(
                    configuredRuntimePoints: 12,
                    magnificationPercent: 100
                )
            )
        XCTAssertTrue(
            sourceCoordinator.enqueue(
                .relative([-1]),
                workspaceId: workspace.id,
                deferFlush: true
            )
        )
        guard let detached =
                sourceManager.detachWorkspace(tabId: workspace.id) else {
            XCTFail("Expected the source manager to detach the workspace")
            return
        }
        destinationManager.attachWorkspace(detached, select: true)
        let pane = try? XCTUnwrap(
            workspace.bonsplitController.focusedPaneId
        )
        guard let pane,
              let projectedTerminal =
                workspace.sessionSnapshot(
                    includeScrollback: false,
                    restorableAgentIndex: .empty
                ).panels.compactMap(\.terminal).first,
              let restoredPanel =
                workspace.newTerminalSurface(
                    inPane: pane,
                    focus: false,
                    runtimeSpawnPolicy: .pacedSessionRestore,
                    terminalFontSizeCreationPolicy:
                        .sessionRestore(
                            overrideBasePoints:
                                projectedTerminal.fontSize,
                            representedChangeTokens: Set(
                                projectedTerminal
                                    .fontSizeChangeTokens
                                    ?? []
                            )
                        )
                ) else {
            XCTFail("Expected a projected restored terminal")
            return
        }
        XCTAssertFalse(
            projectedTerminal.fontSizeChangeTokens?.isEmpty
                ?? true
        )

        sourceCoordinator.cancelWindowOwnedWork()
        finishConfigurationBarrier?()
        finishConfigurationBarrier = nil
#if DEBUG
        sourceCoordinator.drainAllForVerification()
        destinationCoordinator.drainAllForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        XCTAssertTrue(
            testPanels.allSatisfy {
                $0.surface.fontSizeLineageSnapshot()?.basePoints == 19
            },
            "Closing the source window must preserve a deferred request owned by the moved workspace"
        )
        XCTAssertEqual(
            restoredPanel.surface
                .fontSizeLineageSnapshot()?
                .basePoints,
            19,
            "Workspace-only promotion must retain the deferred join's projected token"
        )
    }

    @Test
    func testWorkspaceTerminalFontSizeDrainReconcilesMovedOutTerminal() {
        let manager = TabManager()
        guard let sourceWorkspace = manager.selectedWorkspace,
              let sourcePane =
                sourceWorkspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected a source workspace pane")
            return
        }
        let destinationWorkspace = manager.requiredAddTabForTesting(select: false)
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
        coordinator.flushOneDrainForVerification()
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
        coordinator.drainAllForVerification()
#endif
        XCTAssertEqual(
            unvisitedPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "A terminal present when the request began must carry that request through a move"
        )
    }

    @Test
    func testWorkspaceTerminalFontSizeDrainAppliesToUnrelatedEnteringTerminal() {
        let manager = TabManager()
        guard let sourceWorkspace = manager.selectedWorkspace,
              let sourcePane =
                sourceWorkspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected a source workspace pane")
            return
        }
        let destinationWorkspace = manager.requiredAddTabForTesting(select: false)
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
        coordinator.flushOneDrainForVerification()
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
        coordinator.drainAllForVerification()
#endif
        XCTAssertEqual(
            enteringPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "An unrelated entering terminal must receive outstanding destination work"
        )
    }

    @Test
    func testEnteringTerminalReconcilesEachOutstandingRequestToken() {
        let manager = TabManager()
        guard let sourceWorkspace = manager.selectedWorkspace,
              let sourcePane =
                sourceWorkspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected a source workspace pane")
            return
        }
        let destinationWorkspace = manager.requiredAddTabForTesting(select: false)
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
        coordinator.flushOneDrainForVerification()
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
        coordinator.drainAllForVerification()
#endif
        XCTAssertEqual(
            movedPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            18,
            "Each outstanding request must apply exactly once"
        )
    }

    @Test
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
            applyChange: {
                change,
                panel,
                configuredRuntimePoints,
                magnificationPercent in
                if panel === enteringPanel {
                    enteringPanelApplyCount += 1
                }
                return cmuxApplyTerminalFontSizeChange(
                    change,
                    to: panel,
                    configuredRuntimePoints: configuredRuntimePoints,
                    magnificationPercent: magnificationPercent
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
        coordinator.flushOneDrainForVerification()
        XCTAssertLessThanOrEqual(
            enteringPanelApplyCount - callbackApplyCount,
            WorkspaceTerminalFontSizeDrainBudget
                .maximumLiveActionsPerDrain,
            "One drain must keep transfer actions inside its native-action budget"
        )
        coordinator.drainAllForVerification()
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

    @Test
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
            applyChange: {
                change,
                candidate,
                configuredRuntimePoints,
                magnificationPercent in
                guard candidate === panel else { return .applied }
                applyAttemptCount += 1
                guard applyAttemptCount > 1 else { return .failed }
                return cmuxApplyTerminalFontSizeChange(
                    change,
                    to: candidate,
                    configuredRuntimePoints: configuredRuntimePoints,
                    magnificationPercent: magnificationPercent
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

    @Test
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
            applyChange: {
                change,
                candidate,
                configuredRuntimePoints,
                magnificationPercent in
                guard candidate === panel else {
                    return .alreadySatisfied
                }
                applyAttemptCount += 1
                guard applyAttemptCount > 1 else { return .failed }
                return cmuxApplyTerminalFontSizeChange(
                    change,
                    to: candidate,
                    configuredRuntimePoints: configuredRuntimePoints,
                    magnificationPercent: magnificationPercent
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
        coordinator.drainAllForVerification()
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

    @Test
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
            applyChange: {
                change,
                candidate,
                configuredRuntimePoints,
                magnificationPercent in
                guard candidate === panel else {
                    return .alreadySatisfied
                }
                applyAttemptCount += 1
                let outcome = cmuxApplyTerminalFontSizeChange(
                    change,
                    to: candidate,
                    configuredRuntimePoints: configuredRuntimePoints,
                    magnificationPercent: magnificationPercent
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
        coordinator.drainAllForVerification()
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

    @Test
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
            applyChange: { _, candidate, _, _ in
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
        coordinator.flushOneDrainForVerification()
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

    @Test
    func testBlockedTransferStageDoesNotWakeParkedOwnerOrSpin() {
        let sourceManager = TabManager()
        let destinationManager = TabManager()
        guard let sourceWorkspace = sourceManager.selectedWorkspace,
              let sourcePanelId = sourceWorkspace.focusedPanelId,
              let sourcePanel =
                sourceWorkspace.terminalPanel(for: sourcePanelId),
              let destinationWorkspace =
                destinationManager.selectedWorkspace else {
            XCTFail("Expected source and destination terminals")
            return
        }

        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        let sourceScheduler = ManualWorkspaceFontSizeDrainScheduler()
        let destinationScheduler =
            ManualWorkspaceFontSizeDrainScheduler()
        var sourceApplyAttemptCount = 0
        let sourceCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: sourceManager,
                arbiter: arbiter,
                schedule:
                    sourceScheduler.schedule(delay:action:),
                applyChange: { _, candidate, _, _ in
                    guard candidate === sourcePanel else {
                        return .alreadySatisfied
                    }
                    sourceApplyAttemptCount += 1
                    return .failed
                }
            )
        let destinationCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: destinationManager,
                arbiter: arbiter,
                schedule:
                    destinationScheduler
                        .schedule(delay:action:)
            )
        defer {
            sourceCoordinator.cancelAll()
            destinationCoordinator.cancelAll()
        }

        XCTAssertTrue(
            sourceCoordinator.enqueue(
                .relative([-1]),
                workspaceId: sourceWorkspace.id,
                deferFlush: true
            )
        )
        XCTAssertTrue(
            destinationCoordinator.enqueue(
                .relative([-1]),
                workspaceId: destinationWorkspace.id,
                deferFlush: true
            )
        )
#if DEBUG
        sourceCoordinator.flushOneDrainForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        sourceCoordinator.terminalWillLeaveWorkspace(
            sourcePanel,
            workspace: sourceWorkspace
        )
        guard let sourceRetryIndex =
                sourceScheduler.delays.indices.last else {
            XCTFail("Expected the source mutation backoff")
            return
        }
        sourceScheduler.fire(at: sourceRetryIndex)
        XCTAssertGreaterThanOrEqual(sourceApplyAttemptCount, 2)

        let sourceScheduleCount = sourceScheduler.delays.count
        let destinationScheduleCount =
            destinationScheduler.delays.count
        destinationCoordinator.terminalDidEnterWorkspace(
            sourcePanel,
            workspace: destinationWorkspace
        )

        XCTAssertEqual(
            sourceScheduler.delays.count,
            sourceScheduleCount,
            "A blocked later stage must not reset or reschedule the parked stage owner"
        )
        guard destinationScheduleCount > 0 else {
            XCTFail("Expected the destination's coalescing drain")
            return
        }
        destinationScheduler.fire(
            at: destinationScheduleCount - 1
        )
        XCTAssertEqual(
            destinationScheduler.delays.count,
            destinationScheduleCount,
            "A blocked transfer stage must wait for transfer progress instead of scheduling a zero-delay spin"
        )
    }

    @Test
    func testParkedFontSizeRetryDoesNotRetainUnvisitedPanels() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected an initial workspace")
            return
        }
        for _ in 0..<3 {
            let panel = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            workspace.panels[panel.id] = panel
        }

        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        var failedPanelId: UUID?
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: scheduler.schedule(delay:action:),
            applyChange: { _, candidate, _, _ in
                if failedPanelId == nil {
                    failedPanelId = candidate.id
                }
                return candidate.id == failedPanelId
                    ? .failed
                    : .alreadySatisfied
            }
        )
        defer { coordinator.cancelAll() }

        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.flushOneDrainForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        scheduler.fire(at: 1)

        guard let failedPanelId else {
            XCTFail("Expected a failed terminal")
            return
        }
        var removablePanel =
            workspace.panels.values
                .compactMap({ $0 as? TerminalPanel })
                .first(where: { $0.id != failedPanelId })
        guard let removablePanelId = removablePanel?.id else {
            XCTFail("Expected an unvisited terminal")
            return
        }
        weak var weakRemovablePanel = removablePanel
        workspace.panels.removeValue(forKey: removablePanelId)
        removablePanel = nil

        XCTAssertNil(
            weakRemovablePanel,
            "A parked discovery must not retain panels removed from the owner"
        )
    }

    @Test
    func testClosingFailedWorkspacePanelWakesParkedRequest() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected an initial workspace")
            return
        }
        let follower = TerminalPanel(
            workspaceId: workspace.id,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        workspace.panels[follower.id] = follower
        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        var failedPanel: TerminalPanel?
        var failedAttemptCount = 0
        var successfulPanelIds: Set<UUID> = []
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: scheduler.schedule(delay:action:),
            applyChange: { _, candidate, _, _ in
                if failedPanel == nil {
                    failedPanel = candidate
                }
                if candidate === failedPanel {
                    failedAttemptCount += 1
                    return .failed
                }
                successfulPanelIds.insert(candidate.id)
                return .alreadySatisfied
            }
        )
        defer { coordinator.cancelAll() }

        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.flushOneDrainForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        scheduler.fire(at: 1)
        XCTAssertEqual(failedAttemptCount, 2)
        XCTAssertEqual(scheduler.delays.count, 2)

        guard let failedPanel else {
            XCTFail("Expected a failed terminal candidate")
            return
        }
        workspace.discardClosedPanelLifecycleState(
            panelId: failedPanel.id,
            paneId: nil,
            panel: failedPanel,
            origin: "font_size_retry_test",
            closePanel: false,
            publishSurfaceClosedEvent: false,
            clearSurfaceNotifications: false,
            requestTransferredRemoteCleanup: false
        )

        XCTAssertGreaterThan(
            scheduler.delays.count,
            2,
            "Removing the failed panel must wake the parked request"
        )
        if scheduler.delays.count > 2 {
            scheduler.fire(at: 2)
        }
        XCTAssertFalse(successfulPanelIds.isEmpty)
#if DEBUG
        XCTAssertEqual(coordinator.pendingRequestCountForVerification, 0)
#endif
    }

    @Test
    func testRemovingAllFailedDockPanelsWakesParkedRequest() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let workspacePanelId = workspace.focusedPanelId else {
            XCTFail("Expected an initial workspace terminal")
            return
        }
        let windowDock = manager.makeWindowDockStore(windowId: UUID())
        let dockPanel = TerminalPanel(
            workspaceId: windowDock.workspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        windowDock.panels[dockPanel.id] = dockPanel
        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        var dockApplyAttemptCount = 0
        var successfulPanelIds: Set<UUID> = []
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: scheduler.schedule(delay:action:),
            applyChange: { _, candidate, _, _ in
                if candidate === dockPanel {
                    dockApplyAttemptCount += 1
                    return .failed
                }
                successfulPanelIds.insert(candidate.id)
                return .alreadySatisfied
            }
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
        coordinator.flushOneDrainForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        scheduler.fire(at: 1)
        XCTAssertEqual(dockApplyAttemptCount, 2)
        XCTAssertEqual(scheduler.delays.count, 2)

        windowDock.closeAllPanels()

        XCTAssertGreaterThan(
            scheduler.delays.count,
            2,
            "Dock teardown must wake a request parked on a removed terminal"
        )
        if scheduler.delays.count > 2 {
            scheduler.fire(at: 2)
        }
        XCTAssertTrue(successfulPanelIds.contains(workspacePanelId))
#if DEBUG
        XCTAssertEqual(coordinator.pendingRequestCountForVerification, 0)
#endif
    }

    @Test
    func testRemovingFailedRemoteTmuxPaneWakesParkedRequest() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let outerPanelId = workspace.focusedPanelId,
              let outerPanel =
                workspace.terminalPanel(for: outerPanelId) else {
            XCTFail("Expected an initial workspace terminal")
            return
        }
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"),
            sessionName: "font-size-removal"
        )
        let initialLayout = RemoteTmuxLayoutNode(
            width: 80,
            height: 24,
            x: 0,
            y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(
                    width: 40,
                    height: 24,
                    x: 0,
                    y: 0,
                    content: .pane(11)
                ),
                RemoteTmuxLayoutNode(
                    width: 39,
                    height: 24,
                    x: 41,
                    y: 0,
                    content: .pane(22)
                ),
            ])
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: outerPanelId,
            connection: connection,
            layout: initialLayout,
            makePanel: { _ in
                workspace.makeRemoteTmuxPanePanel(onInput: { _ in })
            }
        )
        workspace.setRemoteTmuxWindowMirror(
            mirror,
            forPanelId: outerPanelId
        )
        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        var failedPanel: TerminalPanel?
        var failedAttemptCount = 0
        var successfulPanelIds: Set<UUID> = []
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            schedule: scheduler.schedule(delay:action:),
            applyChange: { _, candidate, _, _ in
                if candidate === outerPanel {
                    successfulPanelIds.insert(candidate.id)
                    return .alreadySatisfied
                }
                if failedPanel == nil {
                    failedPanel = candidate
                }
                if candidate === failedPanel {
                    failedAttemptCount += 1
                    return .failed
                }
                successfulPanelIds.insert(candidate.id)
                return .alreadySatisfied
            }
        )
        defer {
            workspace.setRemoteTmuxWindowMirror(
                nil,
                forPanelId: outerPanelId
            )
            mirror.teardown()
            coordinator.cancelAll()
        }

        coordinator.enqueue(
            .relative([-1]),
            workspaceId: workspace.id,
            deferFlush: true
        )
#if DEBUG
        coordinator.flushOneDrainForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        scheduler.fire(at: 1)
        XCTAssertEqual(failedAttemptCount, 2)
        XCTAssertEqual(scheduler.delays.count, 2)

        guard let failedPanel,
              let failedPaneId = mirror.panelsByPaneId.first(
                where: { $0.value === failedPanel }
              )?.key,
              let survivingPaneId = mirror.panelsByPaneId.keys.first(
                where: { $0 != failedPaneId }
              ) else {
            XCTFail("Expected failed and surviving remote panes")
            return
        }
        mirror.reconcile(
            layout: RemoteTmuxLayoutNode(
                width: 80,
                height: 24,
                x: 0,
                y: 0,
                content: .pane(survivingPaneId)
            )
        )

        XCTAssertGreaterThan(
            scheduler.delays.count,
            2,
            "Removing a failed remote pane must wake the parked request"
        )
        if scheduler.delays.count > 2 {
            scheduler.fire(at: 2)
        }
        guard let survivingPanel =
                mirror.panel(forPane: survivingPaneId) else {
            XCTFail("Expected the surviving remote pane")
            return
        }
        XCTAssertTrue(successfulPanelIds.contains(survivingPanel.id))
#if DEBUG
        XCTAssertEqual(coordinator.pendingRequestCountForVerification, 0)
#endif
    }

    @Test
    func testClosingWindowCancelsRequestsOwnedByForeignCoordinator() {
        let sourceManager = TabManager()
        let closingManager = TabManager()
        guard let movedWorkspace = sourceManager.selectedWorkspace,
              let movedPanelId = movedWorkspace.focusedPanelId,
              let movedPanel =
                movedWorkspace.terminalPanel(for: movedPanelId) else {
            XCTFail("Expected a movable workspace terminal")
            return
        }
        let closingDock = closingManager.makeWindowDockStore(
            windowId: UUID()
        )
        let closingDockPanel = TerminalPanel(
            workspaceId: closingDock.workspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        closingDock.panels[closingDockPanel.id] = closingDockPanel
        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        var mutatedPanelIds: Set<UUID> = []
        let sourceCoordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: sourceManager,
            arbiter: arbiter,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:),
            applyChange: { _, candidate, _, _ in
                mutatedPanelIds.insert(candidate.id)
                return .alreadySatisfied
            }
        )
        let closingCoordinator =
            WorkspaceTerminalFontSizeCoordinator(
                tabManager: closingManager,
                arbiter: arbiter,
                schedule: ManualWorkspaceFontSizeDrainScheduler()
                    .schedule(delay:action:),
                applyChange: { _, candidate, _, _ in
                    mutatedPanelIds.insert(candidate.id)
                    return .alreadySatisfied
                }
            )
        closingCoordinator.attachWindowDock(closingDock)
        defer {
            sourceCoordinator.cancelAll()
            closingCoordinator.cancelAll()
            closingDock.closeAllPanels()
        }

        sourceCoordinator.enqueue(
            .relative([-1]),
            workspaceId: movedWorkspace.id,
            deferFlush: true
        )
        guard let detached =
                sourceManager.detachWorkspace(
                    tabId: movedWorkspace.id
                ) else {
            XCTFail("Expected the workspace to detach")
            return
        }
        closingManager.attachWorkspace(detached, select: true)
        closingCoordinator.enqueue(
            .relative([-1]),
            workspaceId: movedWorkspace.id,
            deferFlush: true
        )

        closingCoordinator.cancelWindowOwnedWork()
#if DEBUG
        sourceCoordinator.drainAllForVerification()
        closingCoordinator.drainAllForVerification()
#endif

        XCTAssertFalse(mutatedPanelIds.contains(movedPanel.id))
        XCTAssertFalse(
            mutatedPanelIds.contains(closingDockPanel.id),
            "Window close must cancel work even when a foreign coordinator owns it"
        )
    }

    @Test
    func testConfigurationRefreshWaitsForMultiTurnFontDrain() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected an initial workspace")
            return
        }
        for _ in 0..<20 {
            let panel = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            workspace.panels[panel.id] = panel
        }
        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            arbiter: arbiter,
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
        coordinator.flushOneDrainForVerification()
        XCTAssertGreaterThan(coordinator.pendingRequestCountForVerification, 0)
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        var didRefreshConfiguration = false
        arbiter.performWhenFontSizeWorkIsIdle {
            didRefreshConfiguration = true
        }
        XCTAssertFalse(
            didRefreshConfiguration,
            "Surface config refresh must wait for a multi-turn request"
        )

#if DEBUG
        coordinator.drainAllForVerification()
#endif
        XCTAssertTrue(didRefreshConfiguration)
    }

    @Test
    func testExtendedConfigurationBarrierWaitsForAsyncReconciliation() {
        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        var releaseReconciliation: (@MainActor () -> Void)?
        var observedOrder: [String] = []

        arbiter.performWhenFontSizeWorkIsIdle {
            observedOrder.append("config")
            releaseReconciliation =
                arbiter.extendCurrentFontSizeWorkIdleBarrier()
        }
        arbiter.performWhenFontSizeWorkIsIdle {
            observedOrder.append("next")
        }

        XCTAssertEqual(observedOrder, ["config"])
        releaseReconciliation?()
        XCTAssertEqual(observedOrder, ["config", "next"])
    }

    @Test
    func testConfigurationFontReconcilerBoundsCaptureBeforeApply() {
        let scheduler =
            ManualTerminalFontConfigurationReloadScheduler()
        let reconciler =
            TerminalFontConfigurationReloadReconciler(
                maximumSurfaceVisitsPerDrain: 3,
                schedule: scheduler.schedule(action:)
            )
        var nextCaptureIndex = 0
        var captured: [Int] = []
        var reconciled: [Int] = []
        var didApplyConfiguration = false
        var didComplete = false

        reconciler.reconcileIncrementally(
            captureNextWork: {
                guard nextCaptureIndex < 8 else { return nil }
                let index = nextCaptureIndex
                nextCaptureIndex += 1
                captured.append(index)
                return .init(attempt: {
                    reconciled.append(index)
                    return true
                })
            },
            applyConfiguration: {
                didApplyConfiguration = true
            },
            completion: {
                didComplete = true
            }
        )

        scheduler.fire(at: 0)
        XCTAssertEqual(captured, [0, 1, 2])
        XCTAssertFalse(didApplyConfiguration)
        XCTAssertTrue(reconciled.isEmpty)

        scheduler.fire(at: 1)
        XCTAssertEqual(captured, [0, 1, 2, 3, 4, 5])
        XCTAssertFalse(didApplyConfiguration)
        XCTAssertTrue(reconciled.isEmpty)

        scheduler.fire(at: 2)
        XCTAssertEqual(captured, [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertTrue(didApplyConfiguration)
        XCTAssertTrue(reconciled.isEmpty)
        XCTAssertFalse(didComplete)

        scheduler.fire(at: 3)
        XCTAssertEqual(reconciled, [0, 1, 2])
        scheduler.fire(at: 4)
        XCTAssertEqual(reconciled, [0, 1, 2, 3, 4, 5])
        scheduler.fire(at: 5)
        XCTAssertEqual(reconciled, [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertTrue(didComplete)
    }

    @Test
    func testFullConfigurationReloadStagesAppearanceUntilConfigurationCommit()
        throws {
#if DEBUG
        let app = GhosttyApp.shared
        let originalProfile =
            GhosttyStartupAppearancePreviewState.profile
        let originalBackgroundHex =
            app.defaultBackgroundColor.hexString()
        let targetProfile: GhosttyStartupAppearancePreviewProfile =
            originalBackgroundHex.caseInsensitiveCompare("#101820")
                == .orderedSame
            ? .freshInstall
            : .userExplicitColors
        let retainedPanels = (0..<16).map { _ in
            TerminalPanel(
                workspaceId: UUID(),
                runtimeSpawnPolicy: .pacedSessionRestore
            )
        }

        let reloadCompleted = expectation(
            description: "staged appearance reload completed"
        )
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { _ in
            reloadCompleted.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            GhosttyStartupAppearancePreviewState.profile =
                originalProfile
            GhosttyConfig.invalidateLoadCache()

            let restoreCompleted = expectation(
                description: "original appearance restored"
            )
            let restoreObserver =
                NotificationCenter.default.addObserver(
                    forName: .ghosttyConfigDidReload,
                    object: nil,
                    queue: .main
                ) { _ in
                    restoreCompleted.fulfill()
                }
            app.reloadConfiguration(
                source: "test.restoreStagedAppearance",
                reloadSettingsFromFile: false
            )
            wait(for: [restoreCompleted], timeout: 5)
            NotificationCenter.default.removeObserver(
                restoreObserver
            )
            withExtendedLifetime(retainedPanels) {}
        }

        GhosttyStartupAppearancePreviewState.profile =
            targetProfile
        GhosttyConfig.invalidateLoadCache()
        app.reloadConfiguration(
            source: "test.stageAppearance",
            reloadSettingsFromFile: false,
            preferredColorScheme: .light
        )

        XCTAssertEqual(
            app.defaultBackgroundColor.hexString(),
            originalBackgroundHex,
            "A pending full reload must not publish its new background before the matching Ghostty config commits"
        )
        wait(for: [reloadCompleted], timeout: 5)
        XCTAssertNotEqual(
            app.defaultBackgroundColor.hexString(),
            originalBackgroundHex,
            "The staged appearance must publish when the full configuration commits"
        )
#else
        throw XCTSkip("Startup appearance previews require DEBUG")
#endif
    }

    @Test
    func testConfigurationReloadRemainsActiveUntilAsyncReconciliationCompletes()
        throws {
#if DEBUG
        let app = GhosttyApp.shared
        let retainedPanels = (0..<16).map { _ in
            TerminalPanel(
                workspaceId: UUID(),
                runtimeSpawnPolicy: .pacedSessionRestore
            )
        }
        let reloadCompleted = expectation(
            description: "asynchronous configuration reload completed"
        )

        app.reloadConfiguration(
            source: "test.reloadLifetime",
            reloadSettingsFromFile: false
        ) {
            reloadCompleted.fulfill()
        }

        XCTAssertTrue(
            app.isConfigurationReloadActive,
            "Appearance synchronization must stay deferred while incremental reconciliation is pending"
        )
        wait(for: [reloadCompleted], timeout: 5)
        XCTAssertFalse(app.isConfigurationReloadActive)
        withExtendedLifetime(retainedPanels) {}
#else
        throw XCTSkip(
            "Configuration reload lifetime requires DEBUG"
        )
#endif
    }

    @Test
    func testConfigurationReloadCoordinatorBoundsCompletionBearingRequests() {
        let coordinator =
            TerminalConfigurationReloadCoordinator()
        let maximumCompletionCount = 32

        for index in 0..<100 {
            _ = coordinator.enqueue(
                TerminalPendingConfigurationReload(
                    soft: true,
                    source: "test.completionBound.\(index)",
                    reloadSettingsFromFile: false,
                    preferredColorScheme: nil,
                    completions: [{ _ = index }]
                )
            )
        }

        let request = coordinator.takePendingRequest()
        XCTAssertEqual(
            request?.completions.count,
            maximumCompletionCount,
            "Coalesced reloads must retain a bounded number of completion closures"
        )

        for index in 100..<200 {
            _ = coordinator.enqueue(
                TerminalPendingConfigurationReload(
                    soft: true,
                    source: "test.activeCompletionBound.\(index)",
                    reloadSettingsFromFile: false,
                    preferredColorScheme: nil,
                    completions: [{ _ = index }]
                )
            )
        }

        XCTAssertTrue(coordinator.finishReload())
        let requestQueuedBehindActiveReload =
            coordinator.takePendingRequest()
        XCTAssertEqual(
            requestQueuedBehindActiveReload?.completions.count,
            0,
            "The completion bound must include the active reload, not only the pending request"
        )
    }

    @Test
    func testConfigurationReloadQueuesRequestDuringAsyncReconciliation()
        throws {
#if DEBUG
        let app = GhosttyApp.shared
        let retainedPanels = (0..<16).map { _ in
            TerminalPanel(
                workspaceId: UUID(),
                runtimeSpawnPolicy: .pacedSessionRestore
            )
        }
        let startingGeneration =
            app.terminalFontConfigurationGeneration
        let firstReloadCompleted = expectation(
            description: "first configuration reload completed"
        )
        let secondReloadCompleted = expectation(
            description: "queued configuration reload completed"
        )
        var firstCompletionGeneration: UInt64?
        var secondCompletionGeneration: UInt64?

        app.reloadConfiguration(
            source: "test.overlappingReload.first",
            reloadSettingsFromFile: false
        ) {
            firstCompletionGeneration =
                app.terminalFontConfigurationGeneration
            firstReloadCompleted.fulfill()
        }
        app.reloadConfiguration(
            source: "test.overlappingReload.second",
            reloadSettingsFromFile: false
        ) {
            secondCompletionGeneration =
                app.terminalFontConfigurationGeneration
            secondReloadCompleted.fulfill()
        }

        XCTAssertNil(
            secondCompletionGeneration,
            "A request queued during reconciliation must not report success against the active transaction"
        )
        wait(
            for: [
                firstReloadCompleted,
                secondReloadCompleted
            ],
            timeout: 5
        )
        XCTAssertEqual(
            firstCompletionGeneration,
            startingGeneration + 1
        )
        XCTAssertEqual(
            secondCompletionGeneration,
            startingGeneration + 2
        )
        withExtendedLifetime(retainedPanels) {}
#else
        throw XCTSkip(
            "Configuration generation requires DEBUG"
        )
#endif
    }

    @Test
    func testReloadConfigSocketReplyWaitsForConfigurationCommit()
        async throws {
#if DEBUG
        let app = GhosttyApp.shared
        let retainedPanels = (0..<16).map { _ in
            TerminalPanel(
                workspaceId: UUID(),
                runtimeSpawnPolicy: .pacedSessionRestore
            )
        }
        let startingGeneration =
            app.terminalFontConfigurationGeneration
        let replyReturned = expectation(
            description: "reload_config reply returned"
        )
        let responseLock = NSLock()
        nonisolated(unsafe) var response: String?

        CLITestProcessRunner.detachBlockingThread(name: "cmux-test-AppDelegateEqualizeSplitsShortcutTests") {
            let returnedResponse =
                TerminalController.shared.handleSocketLine(
                    "reload_config"
                )
            responseLock.lock()
            response = returnedResponse
            responseLock.unlock()
            replyReturned.fulfill()
        }

        await waitWhileSuspended(
            for: [replyReturned],
            timeout: 5
        )
        responseLock.lock()
        let returnedResponse = response
        responseLock.unlock()
        XCTAssertEqual(returnedResponse, "OK Reloaded config")
        XCTAssertGreaterThan(
            app.terminalFontConfigurationGeneration,
            startingGeneration,
            "The socket must acknowledge success only after the replacement configuration commits"
        )
        withExtendedLifetime(retainedPanels) {}
#else
        throw XCTSkip(
            "Configuration generation requires DEBUG"
        )
#endif
    }

    @Test
    func testReloadConfigBoundsConcurrentWaiters() async {
        let requestCount = 8
        let maximumConcurrentWaiters = 4
        let expectedBusyResponses =
            requestCount - maximumConcurrentWaiters
        let workersReady = DispatchGroup()
        let startWorkers = DispatchSemaphore(value: 0)
        let allResponses = expectation(
            description: "all reload_config responses"
        )
        allResponses.expectedFulfillmentCount =
            requestCount
        let responseCondition = NSCondition()
        nonisolated(unsafe) var responses: [String] = []

        for _ in 0..<requestCount {
            workersReady.enter()
            CLITestProcessRunner.detachBlockingThread(name: "cmux-test-AppDelegateEqualizeSplitsShortcutTests") {
                workersReady.leave()
                startWorkers.wait()
                let response =
                    TerminalController.shared.handleSocketLine(
                        "reload_config"
                    )
                responseCondition.lock()
                responses.append(response)
                responseCondition.broadcast()
                responseCondition.unlock()
                allResponses.fulfill()
            }
        }

        XCTAssertEqual(
            workersReady.wait(
                timeout: .now() + 2
            ),
            .success
        )
        for _ in 0..<requestCount {
            startWorkers.signal()
        }

        responseCondition.lock()
        let admissionDeadline =
            Date().addingTimeInterval(1)
        while responses.count < expectedBusyResponses,
              responseCondition.wait(
                until: admissionDeadline
              ) {}
        let admissionResponses = responses
        responseCondition.unlock()

        XCTAssertEqual(
            admissionResponses.count,
            expectedBusyResponses,
            "Excess reload callers must receive backpressure without waiting for the main-actor reload"
        )
        XCTAssertTrue(
            admissionResponses.allSatisfy {
                $0 == "ERROR: reload_config busy"
            }
        )

        await waitWhileSuspended(
            for: [allResponses],
            timeout: 5
        )
        responseCondition.lock()
        let finalResponses = responses
        responseCondition.unlock()
        XCTAssertEqual(
            finalResponses.filter {
                $0 == "OK Reloaded config"
            }.count,
            maximumConcurrentWaiters
        )
        XCTAssertEqual(
            finalResponses.filter {
                $0 == "ERROR: reload_config busy"
            }.count,
            expectedBusyResponses
        )
    }

    @Test
    func testConfigurationFontReconcilerLateWorkCannotExtendCapture() {
        let scheduler =
            ManualTerminalFontConfigurationReloadScheduler()
        let reconciler =
            TerminalFontConfigurationReloadReconciler(
                maximumSurfaceVisitsPerDrain: 2,
                schedule: scheduler.schedule(action:)
            )
        var nextCaptureIndex = 0
        var lateWorkRuns = 0
        var didApplyConfiguration = false

        reconciler.reconcileIncrementally(
            captureNextWork: {
                guard nextCaptureIndex < 4 else { return nil }
                nextCaptureIndex += 1
                return .init(attempt: { true })
            },
            applyConfiguration: {
                didApplyConfiguration = true
            },
            completion: {}
        )

        scheduler.fire(at: 0)
        XCTAssertTrue(
            reconciler.enqueuePostConfigurationWork(
                .init(attempt: {
                    lateWorkRuns += 1
                    return true
                })
            )
        )
        scheduler.fire(at: 1)
        XCTAssertTrue(
            reconciler.enqueuePostConfigurationWork(
                .init(attempt: {
                    lateWorkRuns += 1
                    return true
                })
            )
        )
        XCTAssertFalse(didApplyConfiguration)

        scheduler.fire(at: 2)

        XCTAssertEqual(nextCaptureIndex, 4)
        XCTAssertTrue(didApplyConfiguration)
        XCTAssertEqual(lateWorkRuns, 0)
        XCTAssertFalse(
            reconciler.enqueuePostConfigurationWork(
                .init(attempt: { true })
            ),
            "New runtimes can use the applied config once capture ends"
        )
    }

    @Test
    func testConfigurationFontReconcilerRetriesFailedWork() {
        let scheduler =
            ManualTerminalFontConfigurationReloadScheduler()
        let reconciler =
            TerminalFontConfigurationReloadReconciler(
                maximumSurfaceVisitsPerDrain: 3,
                schedule: scheduler.schedule(action:)
            )
        var didCapture = false
        var attempts = 0
        var didComplete = false

        reconciler.reconcileIncrementally(
            captureNextWork: {
                guard !didCapture else { return nil }
                didCapture = true
                return .init(attempt: {
                    attempts += 1
                    return attempts > 1
                })
            },
            applyConfiguration: {},
            completion: {
                didComplete = true
            }
        )

        scheduler.fire(at: 0)
        XCTAssertEqual(attempts, 0)
        XCTAssertFalse(didComplete)

        scheduler.fire(at: 1)
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(didComplete)

        scheduler.fire(at: 2)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(didComplete)
    }

    @Test
    func testConfigurationFontReconcilerAbandonsExhaustedWork() {
        let scheduler =
            ManualTerminalFontConfigurationReloadScheduler()
        let reconciler =
            TerminalFontConfigurationReloadReconciler(
                maximumSurfaceVisitsPerDrain: 3,
                maximumAttemptsPerWork: 2,
                schedule: scheduler.schedule(action:)
            )
        var didCapture = false
        var attempts = 0
        var didAbandon = false
        var didComplete = false

        reconciler.reconcileIncrementally(
            captureNextWork: {
                guard !didCapture else { return nil }
                didCapture = true
                return .init(
                    attempt: {
                        attempts += 1
                        return false
                    },
                    abandon: {
                        didAbandon = true
                    }
                )
            },
            applyConfiguration: {},
            completion: {
                didComplete = true
            }
        )

        scheduler.fire(at: 0)
        scheduler.fire(at: 1)
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(didAbandon)
        XCTAssertFalse(didComplete)

        scheduler.fire(at: 2)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(didAbandon)
        XCTAssertTrue(didComplete)
    }

    @Test
    func testConfigurationReloadReadsMagnificationAfterSettingsReload() {
        var storedMagnificationPercent = 100

        let transaction =
            TerminalFontConfigurationReloadTransaction.prepare(
                appliedMagnificationPercent: 100,
                reloadSettings: {
                    storedMagnificationPercent = 200
                },
                storedMagnificationPercent: {
                    storedMagnificationPercent
                }
            )

        XCTAssertEqual(
            transaction.previousMagnificationPercent,
            100
        )
        XCTAssertEqual(
            transaction.targetMagnificationPercent,
            200
        )
        XCTAssertTrue(
            transaction.magnificationDidChange,
            "A soft reload must promote to a full config rebuild when its imported scale changed"
        )
    }

    @Test
    func testConfigurationRefreshWakesParkedFontMutation() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected an initial workspace terminal")
            return
        }
        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        var applyAttemptCount = 0
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            arbiter: arbiter,
            schedule: scheduler.schedule(delay:action:),
            applyChange: {
                change,
                candidate,
                configuredRuntimePoints,
                magnificationPercent in
                guard candidate === panel else {
                    return .alreadySatisfied
                }
                applyAttemptCount += 1
                guard applyAttemptCount > 2 else { return .failed }
                return cmuxApplyTerminalFontSizeChange(
                    change,
                    to: candidate,
                    configuredRuntimePoints: configuredRuntimePoints,
                    magnificationPercent: magnificationPercent
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
        coordinator.flushOneDrainForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        scheduler.fire(at: 1)
        XCTAssertEqual(applyAttemptCount, 2)

        var didRefreshConfiguration = false
        arbiter.performWhenFontSizeWorkIsIdle {
            didRefreshConfiguration = true
        }
        XCTAssertFalse(didRefreshConfiguration)
        XCTAssertGreaterThan(
            scheduler.delays.count,
            2,
            "The config barrier must retry parked native work"
        )
        if scheduler.delays.count > 2 {
            scheduler.fire(at: 2)
        }
        XCTAssertEqual(applyAttemptCount, 3)
        XCTAssertTrue(didRefreshConfiguration)
    }

    @Test
    func testFontMutationAfterConfigurationBarrierWaitsForRefresh() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let observedPanel = workspace.terminalPanel(
                for: panelId
              ) else {
            XCTFail("Expected an initial workspace terminal")
            return
        }
        for _ in 0..<20 {
            let panel = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            workspace.panels[panel.id] = panel
        }
        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        var observedOrder: [String] = []
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            arbiter: arbiter,
            schedule: ManualWorkspaceFontSizeDrainScheduler()
                .schedule(delay:action:),
            applyChange: {
                change,
                candidate,
                configuredRuntimePoints,
                magnificationPercent in
                if candidate === observedPanel {
                    if change == .relative([-1]) {
                        observedOrder.append("decrease")
                    } else if change == .relative([1]) {
                        observedOrder.append("increase")
                    }
                }
                return cmuxApplyTerminalFontSizeChange(
                    change,
                    to: candidate,
                    configuredRuntimePoints: configuredRuntimePoints,
                    magnificationPercent: magnificationPercent
                )
            }
        )
        defer { coordinator.cancelAll() }

        XCTAssertTrue(
            coordinator.enqueue(
                .relative([-1]),
                workspaceId: workspace.id,
                deferFlush: true
            )
        )
#if DEBUG
        coordinator.flushOneDrainForVerification()
        XCTAssertGreaterThan(coordinator.pendingRequestCountForVerification, 0)
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        arbiter.performWhenFontSizeWorkIsIdle {
            observedOrder.append("configRefresh")
        }
        XCTAssertTrue(
            coordinator.enqueue(
                .relative([1]),
                workspaceId: workspace.id,
                deferFlush: true
            ),
            "Font input after the barrier must remain accepted"
        )

#if DEBUG
        coordinator.drainAllForVerification()
#endif
        XCTAssertEqual(
            observedOrder,
            ["decrease", "configRefresh", "increase"]
        )
    }

    @Test
    func testGhosttyAppConfigUpdateWaitsForFontBarrier() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected an initial workspace terminal")
            return
        }
        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        var applyAttemptCount = 0
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            arbiter: appDelegate.workspaceTerminalFontSizeArbiter,
            schedule: scheduler.schedule(delay:action:),
            applyChange: {
                change,
                candidate,
                configuredRuntimePoints,
                magnificationPercent in
                guard candidate === panel else {
                    return .alreadySatisfied
                }
                applyAttemptCount += 1
                guard applyAttemptCount > 2 else { return .failed }
                return cmuxApplyTerminalFontSizeChange(
                    change,
                    to: candidate,
                    configuredRuntimePoints: configuredRuntimePoints,
                    magnificationPercent: magnificationPercent
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
        coordinator.flushOneDrainForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        scheduler.fire(at: 1)
        XCTAssertEqual(applyAttemptCount, 2)

        var didUpdateGhosttyAppConfig = false
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { _ in
            didUpdateGhosttyAppConfig = true
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        GhosttyApp.shared.reloadConfiguration(
            soft: true,
            source: "test.fontBarrier",
            reloadSettingsFromFile: false
        )
        XCTAssertFalse(
            didUpdateGhosttyAppConfig,
            "The app config update itself must wait behind font work"
        )
        XCTAssertGreaterThan(scheduler.delays.count, 2)
        if scheduler.delays.count > 2 {
            scheduler.fire(at: 2)
        }
        XCTAssertEqual(applyAttemptCount, 3)
        XCTAssertTrue(didUpdateGhosttyAppConfig)
    }

    @Test
    func testConfigurationBarrierSettlesPersistentNativeFailure() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected an initial workspace terminal")
            return
        }
        let arbiter = WorkspaceTerminalFontSizeCoordinator.Arbiter()
        let scheduler = ManualWorkspaceFontSizeDrainScheduler()
        var applyAttemptCount = 0
        let coordinator = WorkspaceTerminalFontSizeCoordinator(
            tabManager: manager,
            arbiter: arbiter,
            schedule: scheduler.schedule(delay:action:),
            applyChange: { _, candidate, _, _ in
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
        coordinator.flushOneDrainForVerification()
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif
        scheduler.fire(at: 1)
        XCTAssertEqual(applyAttemptCount, 2)

        var didRunConfigurationBarrier = false
        arbiter.performWhenFontSizeWorkIsIdle {
            didRunConfigurationBarrier = true
        }
        var nextScheduledDrain = 2
        while !didRunConfigurationBarrier,
              nextScheduledDrain < scheduler.delays.count,
              nextScheduledDrain < 10 {
            scheduler.fire(at: nextScheduledDrain)
            nextScheduledDrain += 1
        }

        XCTAssertTrue(
            didRunConfigurationBarrier,
            "A permanent native failure must not hold config forever"
        )
        XCTAssertLessThan(nextScheduledDrain, 10)
#if DEBUG
        XCTAssertEqual(coordinator.pendingRequestCountForVerification, 0)
#endif
    }

    @Test
    func testFontRequestSnapshotsMagnificationAcrossDrainTurns() {
        let defaults = UserDefaults.standard
        let originalPercent = defaults.object(
            forKey: GlobalFontMagnification.percentKey
        )
        defaults.set(
            GlobalFontMagnification.defaultPercent,
            forKey: GlobalFontMagnification.percentKey
        )
        GhosttyConfig.invalidateLoadCache()
        defer {
            if let originalPercent {
                defaults.set(
                    originalPercent,
                    forKey: GlobalFontMagnification.percentKey
                )
            } else {
                defaults.removeObject(
                    forKey: GlobalFontMagnification.percentKey
                )
            }
            GhosttyConfig.invalidateLoadCache()
        }

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected an initial workspace")
            return
        }
        var panels = workspace.panels.values.compactMap {
            $0 as? TerminalPanel
        }
        for _ in 0..<20 {
            let panel = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            workspace.panels[panel.id] = panel
            panels.append(panel)
        }
        for panel in panels {
            panel.surface.recordCurrentFontSizeLineage(
                TerminalFontSizeLineage(
                    basePoints: 20,
                    isExplicitOverride: true
                )
            )
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
        coordinator.flushOneDrainForVerification()
        XCTAssertGreaterThan(coordinator.pendingRequestCountForVerification, 0)
#else
        XCTFail("Workspace font-size coalescer hooks require DEBUG")
        return
#endif

        defaults.set(
            GlobalFontMagnification.maximumPercent,
            forKey: GlobalFontMagnification.percentKey
        )
        GhosttyConfig.invalidateLoadCache()
#if DEBUG
        coordinator.drainAllForVerification()
#endif

        XCTAssertTrue(
            panels.allSatisfy {
                guard let points =
                        $0.surface.fontSizeLineageSnapshot()?.basePoints else {
                    return false
                }
                return abs(points - 19) < 0.000_1
            },
            "Every drain turn must use the request's magnification snapshot"
        )
    }

    @Test
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

    @Test
    func testZeroNetRelativeChangeMakesProjectedLineageExplicit() {
        let lineage =
            WorkspaceTerminalFontSizeChange
                .relative([1, -1])
                .resultingInheritanceLineage(
                    from: TerminalFontSizeLineage(
                        basePoints: 12,
                        isExplicitOverride: false
                    ),
                    configuredRuntimePoints: 12,
                    magnificationPercent: 100
                )

        XCTAssertEqual(lineage.basePoints, 12)
        XCTAssertTrue(
            lineage.isExplicitOverride,
            "Explicit relative input must claim ownership even when its net numeric delta is zero"
        )
    }

    @Test
    func testResetThenZeroNetRelativeChangeMakesProjectedLineageExplicit() {
        let lineage =
            WorkspaceTerminalFontSizeChange
                .resetThen([1, -1])
                .resultingInheritanceLineage(
                    from: TerminalFontSizeLineage(
                        basePoints: 20,
                        isExplicitOverride: true
                    ),
                    configuredRuntimePoints: 12,
                    magnificationPercent: 100
                )

        XCTAssertEqual(lineage.basePoints, 12)
        XCTAssertTrue(
            lineage.isExplicitOverride,
            "Relative input after reset must claim ownership even when its net numeric delta is zero"
        )
    }

    @Test
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
            applyChange: {
                change,
                candidate,
                configuredRuntimePoints,
                magnificationPercent in
                guard candidate === panel else {
                    return .alreadySatisfied
                }
                applyAttemptCount += 1
                guard applyAttemptCount > 1 else { return .failed }
                return cmuxApplyTerminalFontSizeChange(
                    change,
                    to: candidate,
                    configuredRuntimePoints: configuredRuntimePoints,
                    magnificationPercent: magnificationPercent
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
        coordinator.drainAllForVerification()
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

    @Test
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
        coordinator.flushOneDrainForVerification()
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
        coordinator.drainAllForVerification()
#endif

        XCTAssertEqual(
            restoredPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            11,
            "A restored terminal created after discovery starts must join the active request"
        )
    }

    @Test
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
            applyChange: {
                change,
                candidate,
                configuredRuntimePoints,
                magnificationPercent in
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
                    configuredRuntimePoints: configuredRuntimePoints,
                    magnificationPercent: magnificationPercent
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

    @Test
    func testWindowDockFontSizeDrainAppliesToUnrelatedEnteringTerminal() {
        let manager = TabManager()
        guard let requestedWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected a requested workspace")
            return
        }
        let sourceWorkspace = manager.requiredAddTabForTesting(select: false)
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
        coordinator.flushOneDrainForVerification()
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
        coordinator.drainAllForVerification()
#endif
        XCTAssertEqual(
            enteringPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "An unrelated entering terminal must receive outstanding Dock work"
        )
    }

    @Test
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
        coordinator.flushOneDrainForVerification()
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
        coordinator.drainAllForVerification()
#endif
        XCTAssertEqual(
            dockPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            19,
            "The shared batch must apply once after every sibling finishes"
        )
    }

    @Test
    func testWorkspaceTransferDoesNotCoverAnotherWorkspacesDockEvent() {
        let manager = TabManager()
        guard let firstWorkspace = manager.selectedWorkspace,
              let firstPanelID = firstWorkspace.focusedPanelId,
              let firstPanel =
                firstWorkspace.terminalPanel(for: firstPanelID) else {
            XCTFail("Expected an initial workspace terminal")
            return
        }
        let secondWorkspace = manager.requiredAddTabForTesting(select: false)
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
        coordinator.drainAllForVerification()
#endif
        XCTAssertEqual(
            firstPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            20
        )
    }

    @Test
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
        coordinator.drainAllForVerification()
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

    @Test
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
        coordinator.flushOneDrainForVerification()
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
        coordinator.drainAllForVerification()
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
        coordinator.drainAllForVerification()
#endif
        XCTAssertEqual(
            visitedDockPanel.surface.fontSizeLineageSnapshot()?.basePoints,
            18,
            "A transfer marker must not suppress a later destination request"
        )
    }

    @Test
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
        coordinator.drainAllForVerification()
#endif
        XCTAssertEqual(
            panel.surface.fontSizeLineageSnapshot()?.basePoints,
            19
        )
    }

    @Test
    func testClosingWindowCancelsPendingWorkspaceTerminalFontSizeChange() {
        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }
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
            appDelegate.flushPendingWorkspaceTerminalFontSizeChangesForVerification()
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEvent))
            appDelegate.flushPendingWorkspaceTerminalFontSizeChangesForVerification()
            XCTAssertGreaterThan(
                appDelegate.pendingWorkspaceTerminalFontSizeChangeCountForVerification,
                0
            )

            let adjustedBeforeClose = dockPanels.count {
                $0.surface.fontSizeLineageSnapshot()?.basePoints
                    == 19
            }
            XCTAssertGreaterThan(adjustedBeforeClose, 0)
            XCTAssertLessThan(
                adjustedBeforeClose,
                dockPanels.count,
                "The bounded drain must leave accepted work for close settlement"
            )
            window.performClose(nil)

            XCTAssertEqual(
                appDelegate.pendingWorkspaceTerminalFontSizeChangeCountForVerification,
                0,
                "Window teardown must cancel its font-size coordinator"
            )
            let lineagesAfterClose = dockPanels.map {
                $0.surface.fontSizeLineageSnapshot()
            }
            XCTAssertEqual(
                lineagesAfterClose.count {
                    $0?.basePoints == 19
                },
                adjustedBeforeClose,
                "Window close must not bypass the bounded native mutation queue"
            )
            guard let historyItem =
                    ClosedItemHistoryStore.shared
                        .menuSnapshot().items.first,
                  let historyRecord =
                    ClosedItemHistoryStore.shared.removeRecord(
                        id: historyItem.id
                    )?.record,
                  case .window(let closedWindow) =
                    historyRecord.entry else {
                XCTFail("Expected closed-window history")
                return
            }
            let persistedDockFontSizes =
                closedWindow.snapshot.dock?.panels
                    .compactMap(\.terminal?.fontSize)
                ?? []
            XCTAssertEqual(
                persistedDockFontSizes.count,
                dockPanels.count
            )
            XCTAssertTrue(
                persistedDockFontSizes.allSatisfy {
                    abs($0 - 19) < 0.000_1
                },
                "Closed-window history must project every accepted Dock mutation"
            )
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            XCTAssertEqual(
                dockPanels.map { $0.surface.fontSizeLineageSnapshot() },
                lineagesAfterClose,
                "A scheduled drain must not mutate panels after their window closes"
            )
#else
            XCTFail("Workspace font-size coalescer hooks are only available in DEBUG")
            closeWindow(withId: windowId)
#endif
        }
    }

    @Test
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

    @Test
    func testPendingWorkspaceTerminalFontSizeChangePreservesOppositeDirections() {
        var change = WorkspaceTerminalFontSizeChange.relative([1])
        change.appendAdjustment(-1)

        XCTAssertEqual(change, .relative([1, -1]))
    }

    @Test
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

    @Test
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

    @Test
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

    @Test
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

    @Test
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

    @Test
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

    private func mirroredCollectionCount(
        named label: String,
        in value: Any
    ) -> Int? {
        guard let collection = Mirror(reflecting: value).children
            .first(where: { $0.label == label })?.value else {
            return nil
        }
        return Mirror(reflecting: collection).children.count
    }

    private func makeDormantTerminalTransfer(
        panel: TerminalPanel,
        sourceWorkspaceId: UUID
    ) -> Workspace.DetachedSurfaceTransfer {
        Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            sessionRestoreSourceWorkspaceId: nil,
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
            managedAgentResumeBinding: nil,
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

@MainActor
private final class ManualTerminalFontConfigurationReloadScheduler {
    private var actions: [@MainActor @Sendable () -> Void] = []

    func schedule(
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        actions.append(action)
    }

    func fire(at index: Int) {
        guard actions.indices.contains(index) else { return }
        actions[index]()
    }
}
