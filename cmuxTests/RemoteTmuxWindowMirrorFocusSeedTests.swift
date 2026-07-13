import CmuxRemoteSession
import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct RemoteTmuxWindowMirrorFocusSeedTests {
    @Test func activePaneSeedsFromTmuxOnMirrorCreation() {
        let connection = RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        connection.handleMessageForTesting(.windowPaneChanged(windowId: 1, paneId: 5))

        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: Self.twoPaneLayout(left: 4, right: 5),
            appearance: .default,
            makePanel: { _ in nil }
        )

        #expect(mirror.activePaneId == 5)
    }

    @Test func activePaneUpdatesFromTmuxAndReseedsOnReconcile() {
        let connection = RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: Self.twoPaneLayout(left: 4, right: 5),
            appearance: .default,
            makePanel: { _ in nil }
        )
        #expect(mirror.activePaneId == 4)

        connection.handleMessageForTesting(.windowPaneChanged(windowId: 1, paneId: 5))
        mirror.setActivePane(5, fromTmux: true)
        #expect(mirror.activePaneId == 5)

        connection.handleMessageForTesting(.windowPaneChanged(windowId: 1, paneId: 8))
        mirror.reconcile(layout: Self.twoPaneLayout(left: 7, right: 8))
        #expect(mirror.activePaneId == 8)
    }

    @Test func liveWindowPaneChangedUpdatesMirrorBeforeAnotherReconcile() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        workspace.isRemoteTmuxMirror = true
        let host = RemoteTmuxHost(destination: "user@host")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "work")
        let layout = Self.twoPaneLayout(left: 4, right: 5)
        connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            name: "main",
            width: layout.width,
            height: layout.height,
            layout: layout
        )
        connection.windowOrder = [1]
        connection.activePaneByWindow[1] = 4

        let sessionMirror = RemoteTmuxSessionMirror(
            host: host,
            sessionName: "work",
            connection: connection,
            tabManager: manager,
            workspace: workspace
        )
        defer { sessionMirror.detachObserver() }
        let windowMirror = try #require(
            workspace.panels.keys.lazy.compactMap {
                workspace.remoteTmuxWindowMirror(forPanelId: $0)
            }.first
        )
        #expect(windowMirror.activePaneId == 4)

        connection.handleMessageForTesting(.windowPaneChanged(windowId: 1, paneId: 5))

        #expect(windowMirror.activePaneId == 5)
    }

    @Test func reconnectWaitsForAttachDrainBeforeResizingVisibleMirror() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        workspace.isRemoteTmuxMirror = true
        let host = RemoteTmuxHost(destination: "user@host")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "work")
        let layout = Self.twoPaneLayout(left: 4, right: 5)
        connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1, name: "main", width: layout.width, height: layout.height, layout: layout
        )
        connection.windowOrder = [1]

        let sessionMirror = RemoteTmuxSessionMirror(
            host: host,
            sessionName: "work",
            connection: connection,
            tabManager: manager,
            workspace: workspace
        )
        defer { sessionMirror.detachObserver() }
        let windowMirror = try #require(
            workspace.panels.keys.lazy.compactMap {
                workspace.remoteTmuxWindowMirror(forPanelId: $0)
            }.first
        )
        windowMirror.isVisibleForSizing = true
        windowMirror.performSizingPassNow()
        #expect(!windowMirror.isEffectivelyVisibleForSizing)
        #expect(!windowMirror.sizingPassScheduled)

        connection.observers.notifyStateChanged(.connected)

        #expect(!windowMirror.sizingPassScheduled)
        connection.observers.notifyReconnectReady()
        #expect(windowMirror.sizingPassScheduled)
    }

    @Test func reconcileWithUnchangedLayoutDoesNotReassertBonsplitFocus() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        workspace.isRemoteTmuxMirror = true
        let host = RemoteTmuxHost(destination: "user@host")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "work")
        let layout = Self.twoPaneLayout(left: 4, right: 5)
        connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            name: "main",
            width: layout.width,
            height: layout.height,
            layout: layout
        )
        connection.windowOrder = [1]
        connection.activePaneByWindow[1] = 4

        let sessionMirror = RemoteTmuxSessionMirror(
            host: host,
            sessionName: "work",
            connection: connection,
            tabManager: manager,
            workspace: workspace
        )
        defer { sessionMirror.detachObserver() }
        let windowMirror = try #require(
            workspace.panels.keys.lazy.compactMap {
                workspace.remoteTmuxWindowMirror(forPanelId: $0)
            }.first
        )
        #expect(windowMirror.activePaneId == 4)

        let spy = FocusSpyDelegate()
        windowMirror.bonsplitController.delegate = spy
        // Routine %layout-change echoes reconcile an unchanged layout; the
        // already-focused active pane must not be re-asserted (each re-assert
        // mutates Bonsplit focus state and can interrupt typing elsewhere).
        windowMirror.reconcile(layout: Self.twoPaneLayout(left: 4, right: 5))
        #expect(spy.focusedPanes.isEmpty)

        // A genuine active-pane change must still move Bonsplit focus.
        windowMirror.setActivePane(5, fromTmux: true)
        #expect(spy.focusedPanes.count == 1)
    }

    @Test func noopImpositionKeepsTheFirstDividerDragRoutable() throws {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        let layout = Self.twoPaneLayout(left: 4, right: 5)
        let container = CGSize(width: 800, height: 620)
        let geometry = RemoteTmuxMirrorGeometry(
            cellWidthPx: 16,
            cellHeightPx: 34,
            surfacePadWidthPx: 8,
            surfacePadHeightPx: 0,
            scale: 2
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: layout,
            geometrySource: { geometry },
            hostingContentSizeSource: { container },
            makePanel: { _ in nil }
        )
        mirror.noteContainerSize(pointSize: container, scale: 2)
        let metrics = try #require(mirror.nativeLayoutMetrics())
        let plan = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics).plan(
            tree: RemoteTmuxNativeMeasuredSplitTree(
                tree: RemoteTmuxNativeSplitTree(layout: layout), metrics: metrics
            ),
            parentSize: container
        )
        guard case .split(_, let fraction, _, _, _) = plan,
              case .split(let split) = mirror.bonsplitController.treeSnapshot(),
              let splitID = UUID(uuidString: split.id)
        else {
            Issue.record("Expected one planned divider")
            return
        }
        _ = mirror.bonsplitController.setDividerPosition(
            fraction, forSplit: splitID, fromExternal: true
        )
        mirror.lastDividerPositions[splitID] = fraction
        mirror.isVisibleForSizing = true
        mirror.performSizingPassNow()

        let dragged = min(0.9, fraction + 0.05)
        _ = mirror.bonsplitController.setDividerPosition(
            dragged, forSplit: splitID, fromExternal: true
        )
        mirror.syncChangedDividerPositions()

        #expect(mirror.lastDividerPositions[splitID] == dragged)
    }

    @Test func settlementWaitsForPendingPaneRectPublication() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
        workspace.isRemoteTmuxMirror = true
        let originalManager = TerminalController.shared.tabManager
        TerminalController.shared.tabManager = manager
        let host = RemoteTmuxHost(destination: "user@host")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "work")
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-settlement-pending-layout-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(.commandResult(
            commandNumber: 0, lines: [], isError: false
        ))
        let layout = Self.twoPaneLayout(left: 4, right: 5)
        connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1, name: "main", width: layout.width, height: layout.height, layout: layout
        )
        connection.windowOrder = [1]
        let sessionMirror = RemoteTmuxSessionMirror(
            host: host,
            sessionName: "work",
            connection: connection,
            tabManager: manager,
            workspace: workspace
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 620),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            TerminalController.shared.tabManager = originalManager
            sessionMirror.detachObserver()
            window.orderOut(nil)
            window.close()
            writer.close()
            try? pipe.fileHandleForReading.close()
        }
        let mirror = try #require(sessionMirror.windowMirrorByWindowId[1])
        for (index, panel) in mirror.panelsByPaneId.values.enumerated() {
            panel.hostedView.frame = CGRect(x: index * 400, y: 0, width: 400, height: 620)
            window.contentView?.addSubview(panel.hostedView)
            panel.hostedView.setVisibleInUI(true)
        }
        window.orderFront(nil)
        mirror.isVisibleForSizing = true
        mirror.containerSizePt = CGSize(width: 800, height: 620)
        mirror.containerScale = 2
        mirror.geometrySnapshot = RemoteTmuxMirrorGeometry(
            cellWidthPx: 16,
            cellHeightPx: 34,
            surfacePadWidthPx: 8,
            surfacePadHeightPx: 0,
            scale: 2
        )
        mirror.performSizingPassNow()
        let claimed = try #require(connection.lastWindowSizes[1])
        connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1, name: "main", width: claimed.0, height: claimed.1, layout: layout
        )
        mirror.lastRenderedGrids = layout.leavesByPaneID.mapValues { ($0.width, $0.height) }
        connection.pendingLayouts[1] = RemoteTmuxPendingLayout(
            node: layout,
            visibleNode: nil,
            zoomed: false,
            name: "main",
            generation: 2,
            inFlight: true
        )

        let payload = TerminalController.shared.remoteTmuxSizingSettlementPayload()
        let windows = try #require(payload["windows"] as? [[String: Any]])
        let result = try #require(windows.first { ($0["window"] as? Int) == 1 })
        #expect(result["settled"] as? Bool == false)
    }

    private static func twoPaneLayout(left: Int, right: Int) -> RemoteTmuxLayoutNode {
        RemoteTmuxLayoutNode(
            width: 80,
            height: 24,
            x: 0,
            y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(width: 39, height: 24, x: 0, y: 0, content: .pane(left)),
                RemoteTmuxLayoutNode(width: 40, height: 24, x: 40, y: 0, content: .pane(right)),
            ])
        )
    }
}

@MainActor
private final class FocusSpyDelegate: BonsplitDelegate {
    var focusedPanes: [PaneID] = []

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        focusedPanes.append(pane)
    }
}
