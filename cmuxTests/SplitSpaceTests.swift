import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A split must never leave a pane smaller than its tab bar plus a few
/// terminal rows (#15371). It borrows room from the panes it stacks with
/// first, and refuses when even that cannot fit.
@Suite("Split space", .serialized)
@MainActor
struct SplitSpaceTests {
    /// #15371: at a full-size window, five splits down halved the focused
    /// pane each time and left the last two about 27 pt tall, shorter than
    /// their tab bar, so the terminal got 0 pt.
    @Test func fiveSplitsDownAtFullSizeKeepEveryPaneAboveTheMinimum() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 860))

        for _ in 0..<5 {
            let source = try #require(workspace.focusedPanelId)
            #expect(workspace.newTerminalSplitOutcome(from: source, orientation: .vertical).panel != nil)
        }

        // Each split past the fourth borrows from the column: the six panes
        // share it equally instead of halving the last one again.
        let minimumHeight = Double(workspace.splitMinimumPaneSize.height)
        #expect(minimumHeight >= Double(WindowChromeMetrics.bonsplitTabBarHeight) + 3 * 17)
        let panes = workspace.bonsplitController.layoutSnapshot().panes
        #expect(panes.count == 6)
        for pane in panes {
            #expect(pane.frame.height >= minimumHeight, "pane \(pane.paneId) is \(pane.frame.height) pt tall")
        }
    }

    /// When the column is full even after equalizing, the split is refused
    /// and nothing is created.
    @Test func aSplitDownWithNoRoomIsRefused() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 300))
        let first = try #require(workspace.focusedPanelId)
        #expect(workspace.newTerminalSplitOutcome(from: first, orientation: .vertical).panel != nil)
        let panelCount = workspace.panels.count

        let source = try #require(workspace.focusedPanelId)
        let outcome = workspace.newTerminalSplitOutcome(from: source, orientation: .vertical)

        guard case .noSpace = outcome else {
            Issue.record("expected a refused split, got \(outcome)")
            return
        }
        #expect(!outcome.isAccepted)
        #expect(workspace.panels.count == panelCount)
        #expect(workspace.bonsplitController.allPaneIds.count == 2)
        #expect(workspace.focusedPanelId == source)
    }

    /// The width has its own column minimum: a narrow window refuses a third
    /// side-by-side pane but still splits down.
    @Test func aSplitRightUsesTheColumnMinimum() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 400, height: 860))
        let first = try #require(workspace.focusedPanelId)
        #expect(workspace.newTerminalSplitOutcome(from: first, orientation: .horizontal).panel != nil)
        let source = try #require(workspace.focusedPanelId)

        guard case .noSpace = workspace.newTerminalSplitOutcome(from: source, orientation: .horizontal) else {
            Issue.record("expected the third side-by-side pane to be refused")
            return
        }
        #expect(workspace.newTerminalSplitOutcome(from: source, orientation: .vertical).panel != nil)
    }

    @Test func programmaticAndMovingTabHelpersUseTheCentralAdmissionGate() throws {
        let fileDropWorkspace = Workspace()
        defer { fileDropWorkspace.teardownAllPanels() }
        fileDropWorkspace.bonsplitController.setContainerFrame(
            CGRect(x: 0, y: 0, width: 1200, height: 100)
        )
        let fileDropPane = try #require(fileDropWorkspace.bonsplitController.focusedPaneId)
        let fileDropPanelCount = fileDropWorkspace.panels.count
#if DEBUG
        var terminalConstructionRequests: [(command: String?, input: String?)] = []
        fileDropWorkspace.debugTerminalSplitPanelConstructionProbe = { command, input in
            terminalConstructionRequests.append((command, input))
        }
#endif
        #expect(fileDropWorkspace.splitPaneWithNewTerminal(
            targetPane: fileDropPane,
            orientation: .vertical,
            insertFirst: false,
            workingDirectory: nil,
            initialInput: "must-not-run\n",
            remoteStartupCommand: "must-not-start"
        ) == nil)
        #expect(fileDropWorkspace.panels.count == fileDropPanelCount)
#if DEBUG
        #expect(terminalConstructionRequests.isEmpty, "rejected split must not construct or start a terminal")
#endif

        let browserWorkspace = Workspace()
        defer { browserWorkspace.teardownAllPanels() }
        browserWorkspace.bonsplitController.setContainerFrame(
            CGRect(x: 0, y: 0, width: 300, height: 860)
        )
        let browserSource = try #require(browserWorkspace.focusedPanelId)
        let browserPanelCount = browserWorkspace.panels.count
#if DEBUG
        var browserNavigationRequests: [URL?] = []
        browserWorkspace.debugBrowserSplitPanelConstructionProbe = { url in
            browserNavigationRequests.append(url)
        }
#endif
        #expect(browserWorkspace.newBrowserSplit(
            from: browserSource,
            orientation: .horizontal,
            url: URL(string: "https://must-not-navigate.invalid/"),
            allowsExternalBrowserFallback: false
        ) == nil)
        #expect(browserWorkspace.panels.count == browserPanelCount)
#if DEBUG
        #expect(browserNavigationRequests.isEmpty, "rejected split must not construct or navigate a browser")
#endif

        let movingWorkspace = Workspace()
        defer { movingWorkspace.teardownAllPanels() }
        movingWorkspace.bonsplitController.setContainerFrame(
            CGRect(x: 0, y: 0, width: 1200, height: 100)
        )
        let movingPane = try #require(movingWorkspace.bonsplitController.focusedPaneId)
        let movedPanel = try #require(movingWorkspace.newTerminalSurface(inPane: movingPane, focus: false))
        let movedTab = try #require(movingWorkspace.surfaceIdFromPanelId(movedPanel.id))
        #expect(movingWorkspace.splitPaneMovingTab(
            movingPane,
            orientation: .vertical,
            movingTab: movedTab,
            insertFirst: false,
            focusIntent: .preserveCurrent
        ) == nil)
        #expect(movingWorkspace.bonsplitController.allPaneIds.count == 1)
        #expect(movingWorkspace.bonsplitController.tabs(inPane: movingPane).contains { $0.id == movedTab })
    }

    @Test func explicitDividerRatioCannotCreateAnUndersizedChild() throws {
        let terminalWorkspace = Workspace()
        defer { terminalWorkspace.teardownAllPanels() }
        terminalWorkspace.bonsplitController.setContainerFrame(
            CGRect(x: 0, y: 0, width: 1000, height: 860)
        )
        let terminalSource = try #require(terminalWorkspace.focusedPanelId)
        let terminalOutcome = terminalWorkspace.newTerminalSplitOutcome(
            from: terminalSource,
            orientation: .horizontal,
            initialDividerPosition: 0.9
        )
        guard case .noSpace = terminalOutcome else {
            Issue.record("expected the terminal ratio to be refused, got \(terminalOutcome)")
            return
        }

        let borrowingWorkspace = Workspace()
        defer { borrowingWorkspace.teardownAllPanels() }
        borrowingWorkspace.bonsplitController.setContainerFrame(
            CGRect(x: 0, y: 0, width: 600, height: 860)
        )
        let firstBorrowingSource = try #require(borrowingWorkspace.focusedPanelId)
        _ = try #require(borrowingWorkspace.newTerminalSplit(
            from: firstBorrowingSource,
            orientation: .horizontal
        ))
        let skewedSource = try #require(borrowingWorkspace.focusedPanelId)
        _ = try #require(borrowingWorkspace.newTerminalSplit(
            from: skewedSource,
            orientation: .horizontal,
            initialDividerPosition: 0.1
        ))
        let minimumWidth = Double(borrowingWorkspace.splitMinimumPaneSize.width)
        #expect(borrowingWorkspace.bonsplitController.layoutSnapshot().panes.allSatisfy {
            $0.frame.width >= minimumWidth
        })

        let browserWorkspace = Workspace()
        defer { browserWorkspace.teardownAllPanels() }
        browserWorkspace.bonsplitController.setContainerFrame(
            CGRect(x: 0, y: 0, width: 1000, height: 860)
        )
        let browserSource = try #require(browserWorkspace.focusedPanelId)
        #expect(browserWorkspace.newBrowserSplit(
            from: browserSource,
            orientation: .horizontal,
            allowsExternalBrowserFallback: false,
            initialDividerPosition: 0.9
        ) == nil)

        let flags = CmuxFeatureFlags.shared
        let simulatorFlag = CmuxFeatureFlags.simulatorFlag
        let previousSimulatorOverride = flags.overrideValue(for: simulatorFlag)
        flags.setOverride(true, for: simulatorFlag)
        defer { flags.setOverride(previousSimulatorOverride, for: simulatorFlag) }
        let simulatorWorkspace = Workspace()
        defer { simulatorWorkspace.teardownAllPanels() }
        simulatorWorkspace.bonsplitController.setContainerFrame(
            CGRect(x: 0, y: 0, width: 1000, height: 860)
        )
        let simulatorSource = try #require(simulatorWorkspace.focusedPanelId)
        #expect(simulatorWorkspace.newSimulatorSplit(
            from: simulatorSource,
            orientation: .horizontal,
            initialDividerPosition: 0.9
        ) == nil)
    }
}
