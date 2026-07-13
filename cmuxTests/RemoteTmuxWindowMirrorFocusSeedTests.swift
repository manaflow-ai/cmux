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

    @Test func logicallyVisibleDetachedPassWaitsForAHostBeforeCompleting() throws {
        var hostingBound: CGSize?
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: Self.twoPaneLayout(left: 4, right: 5),
            geometrySource: {
                RemoteTmuxMirrorGeometry(
                    cellWidthPx: 16, cellHeightPx: 34,
                    surfacePadWidthPx: 8, surfacePadHeightPx: 0, scale: 2
                )
            },
            hostingContentSizeSource: { hostingBound },
            makePanel: { _ in nil }
        )
        mirror.noteContainerSize(pointSize: CGSize(width: 800, height: 620), scale: 2)
        mirror.isVisibleForSizing = true

        mirror.performSizingPassNow()

        #expect(connection.lastWindowSizes[1] != nil)
        #expect(mirror.lastCompletedSizingInputs == nil)

        hostingBound = CGSize(width: 800, height: 620)
        mirror.performSizingPassNow()

        #expect(mirror.lastCompletedSizingInputs != nil)
        let tree = mirror.bonsplitController.treeSnapshot()
        guard case .split(let split) = tree else {
            Issue.record("Expected one planned divider")
            return
        }
        #expect(split.imposedFirstExtent != nil)
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
