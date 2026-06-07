import Testing
import AppKit
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the mobile workspace-list fidelity fixes: terminals are serialized in
/// the on-screen bonsplit spatial order, a terminal rename re-emits to the phone,
/// and a pure drag-reorder is detected even though it changes no panel-set state.
///
/// `.serialized` because these exercise process-global surface registries via the
/// real `Workspace`/`TabManager`/bonsplit model, which must not run concurrently.
@MainActor
@Suite(.serialized)
struct MobileWorkspaceListFidelityTests {
    /// Builds a workspace with `count` terminals as tabs in a single pane so that
    /// a within-pane `reorderTab` genuinely changes their on-screen order. Returns
    /// the workspace and panel ids in spatial (tab) order.
    private func makeWorkspaceWithTabTerminals(count: Int) throws -> (Workspace, [UUID]) {
        precondition(count >= 1)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        var orderedIds: [UUID] = [try #require(workspace.focusedPanelId)]
        for _ in 1..<count {
            let panel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
            orderedIds.append(panel.id)
        }
        return (workspace, orderedIds)
    }

    /// Builds a workspace with `count` terminals laid out left-to-right via
    /// horizontal splits (each in its own pane), returning the workspace and panel
    /// ids in spatial order.
    private func makeWorkspaceWithSplitTerminals(count: Int) throws -> (Workspace, [UUID]) {
        precondition(count >= 1)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        var orderedIds: [UUID] = [try #require(workspace.focusedPanelId)]
        for _ in 1..<count {
            let previous = try #require(orderedIds.last)
            let panel = try #require(
                workspace.newTerminalSplit(from: previous, orientation: .horizontal, focus: false)
            )
            orderedIds.append(panel.id)
        }
        return (workspace, orderedIds)
    }

    @Test func orderedPanelIdsMatchesBonsplitSpatialOrder() throws {
        let (workspace, createdOrder) = try makeWorkspaceWithSplitTerminals(count: 3)

        // orderedPanelIds is derived from bonsplit's left-to-right tab ordering.
        let ordered = workspace.orderedPanelIds
        #expect(Set(ordered) == Set(createdOrder), "should contain exactly the created panels")

        // It must equal bonsplit's own allTabIds mapping (the spatial source of
        // truth), not dictionary/UUID order.
        let expected = workspace.bonsplitController.allTabIds.compactMap {
            workspace.panelIdFromSurfaceId($0)
        }
        #expect(ordered == expected)
    }

    @Test func reorderingTerminalsChangesObserverHashAndBumpsLayoutVersion() throws {
        // Tabs in one pane so a within-pane reorder genuinely changes their order.
        let (workspace, ordered) = try makeWorkspaceWithTabTerminals(count: 3)
        #expect(ordered.count == 3)

        let versionBefore = workspace.paneLayoutVersion
        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        // Move the first terminal to the end. Same panel set, different spatial order.
        let firstTabId = try #require(workspace.surfaceIdFromPanelId(ordered[0]))
        #expect(workspace.bonsplitController.reorderTab(firstTabId, toIndex: 2))

        // Sanity: the id set is unchanged, but the order changed.
        let afterOrder = workspace.orderedPanelIds
        #expect(Set(afterOrder) == Set(ordered))
        #expect(afterOrder != ordered, "reorder should change the ordered sequence")

        // The reorder must wake the observer (bonsplit selection state is not
        // @Published, so paneLayoutVersion is the only signal).
        #expect(
            workspace.paneLayoutVersion > versionBefore,
            "a pure reorder must bump paneLayoutVersion so the observer re-evaluates"
        )

        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(before != after, "a pure reorder must change the mobile summary hash")
    }

    @Test func renamingTerminalChangesObserverHashAndDisplayedTitle() throws {
        let (workspace, ordered) = try makeWorkspaceWithTabTerminals(count: 2)
        let panelId = try #require(ordered.first)

        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        // A terminal rename sets panelCustomTitles (not panelTitles); the observer
        // must still detect it, and panelTitle must resolve to the custom title that
        // the mobile workspace.list response serializes.
        workspace.setPanelCustomTitle(panelId: panelId, title: "Renamed Terminal")
        #expect(workspace.panelTitle(panelId: panelId) == "Renamed Terminal")

        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(before != after, "a terminal rename must change the mobile summary hash")
    }

    @Test func renamingWorkspaceChangesObserverHashAndDisplayedTitle() throws {
        let (workspace, _) = try makeWorkspaceWithTabTerminals(count: 1)

        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        workspace.setCustomTitle("Renamed Workspace")
        // The mobile workspace.list response sends workspace.title.
        #expect(workspace.title == "Renamed Workspace")

        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(before != after, "a workspace rename must change the mobile summary hash")
    }
}
