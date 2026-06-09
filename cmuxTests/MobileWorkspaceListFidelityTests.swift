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

    /// A pure group-membership move (a workspace's `groupId` changes while the tab
    /// set, group list, panels, title, and pin state stay put) must change the
    /// mobile summary hash so the observer re-emits `workspace.updated`. The phone
    /// nests members under their group header keyed by `group_id`, so a stale hash
    /// here would leave the mobile sidebar showing the workspace in the wrong
    /// section. Guards the per-workspace `$groupId` subscription that drives it.
    @Test func movingWorkspaceBetweenGroupsChangesObserverHash() throws {
        let manager = TabManager()
        let member = try #require(manager.selectedWorkspace)
        // A real group with its own anchor; the member starts ungrouped.
        let groupId = try #require(manager.createWorkspaceGroup(name: "Group A"))
        #expect(member.groupId == nil)

        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId
        )

        // Move the workspace into the group: only `groupId` changes.
        member.groupId = groupId

        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId
        )
        #expect(before != after, "a pure group-membership move must change the mobile summary hash")
    }

    /// A new notification (or clearing the latest one) changes only a workspace's
    /// preview signature, not the tab set, groups, panels, title, or pin state.
    /// The signature must be folded into the summary hash so the observer
    /// re-emits and the phone refreshes the row's preview line + relative time.
    @Test func previewSignatureChangeChangesObserverHash() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)

        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId,
            previewSignatures: [:]
        )
        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId,
            previewSignatures: [workspace.id: 42]
        )
        #expect(before != after, "a preview-signature change must change the mobile summary hash")

        let changed = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId,
            previewSignatures: [workspace.id: 43]
        )
        #expect(after != changed, "a newer notification must change the mobile summary hash")
    }

    /// The mobile preview line must flatten arbitrary notification text into one
    /// short plain-text line: ANSI escapes stripped, control characters and
    /// newlines collapsed, whitespace runs joined, length capped with an ellipsis,
    /// and whitespace-only input dropped entirely.
    @Test func mobilePreviewSanitizeFlattensAndCaps() throws {
        // ANSI SGR + OSC sequences are stripped without leaking payload bytes.
        #expect(
            TerminalController.mobilePreviewSanitize("\u{001B}[31mbuild\u{001B}[0m \u{001B}]0;title\u{0007}done") ==
                "build done"
        )
        // Newlines, tabs, and runs of spaces collapse to single spaces.
        #expect(TerminalController.mobilePreviewSanitize("line one\n\n  line\ttwo   ") == "line one line two")
        // Whitespace-only input yields nil so the row shows no preview.
        #expect(TerminalController.mobilePreviewSanitize(" \n\t ") == nil)
        // Long input is capped with a trailing ellipsis at the documented limit.
        let long = String(repeating: "a", count: 500)
        let capped = try #require(TerminalController.mobilePreviewSanitize(long))
        #expect(capped.count == TerminalController.mobilePreviewMaxLength)
        #expect(capped.hasSuffix("\u{2026}"))
        // Input past the processing cap is never scanned (bounded main-actor
        // work); a huge body still yields the documented capped preview.
        let huge = String(repeating: "b", count: TerminalController.mobilePreviewInputCap * 64)
        let boundedHuge = try #require(TerminalController.mobilePreviewSanitize(huge))
        #expect(boundedHuge.count == TerminalController.mobilePreviewMaxLength)
        #expect(boundedHuge.hasSuffix("\u{2026}"))
        // A short visible head followed by over-cap filler keeps the head and
        // signals the truncation with an ellipsis instead of dropping it.
        let headThenFiller = "ok" + String(repeating: " ", count: TerminalController.mobilePreviewInputCap) + "tail"
        #expect(TerminalController.mobilePreviewSanitize(headThenFiller) == "ok\u{2026}")
        // An OSC sequence left unterminated (e.g. cut by the input cap) is
        // stripped wholly rather than leaking its payload bytes.
        #expect(TerminalController.mobilePreviewSanitize("\u{001B}]0;unterminated title") == nil)
    }
}
