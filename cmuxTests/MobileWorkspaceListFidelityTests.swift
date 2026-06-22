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
        let before = MobileWorkspaceListObserver.summaryHash(
            for: [workspace],
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

        let after = MobileWorkspaceListObserver.summaryHash(
            for: [workspace],
            selectedTabID: workspace.id
        )
        #expect(before != after, "a pure reorder must change the mobile summary hash")
    }

    @Test func renamingTerminalChangesObserverHashAndDisplayedTitle() throws {
        let (workspace, ordered) = try makeWorkspaceWithTabTerminals(count: 2)
        let panelId = try #require(ordered.first)

        let before = MobileWorkspaceListObserver.summaryHash(
            for: [workspace],
            selectedTabID: workspace.id
        )

        // A terminal rename sets panelCustomTitles (not panelTitles); the observer
        // must still detect it, and panelTitle must resolve to the custom title that
        // the mobile workspace.list response serializes.
        workspace.setPanelCustomTitle(panelId: panelId, title: "Renamed Terminal")
        #expect(workspace.panelTitle(panelId: panelId) == "Renamed Terminal")

        let after = MobileWorkspaceListObserver.summaryHash(
            for: [workspace],
            selectedTabID: workspace.id
        )
        #expect(before != after, "a terminal rename must change the mobile summary hash")
    }

    @Test func renamingWorkspaceChangesObserverHashAndDisplayedTitle() throws {
        let (workspace, _) = try makeWorkspaceWithTabTerminals(count: 1)

        let before = MobileWorkspaceListObserver.summaryHash(
            for: [workspace],
            selectedTabID: workspace.id
        )

        workspace.setCustomTitle("Renamed Workspace")
        // The mobile workspace.list response sends workspace.title.
        #expect(workspace.title == "Renamed Workspace")

        let after = MobileWorkspaceListObserver.summaryHash(
            for: [workspace],
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

        let before = MobileWorkspaceListObserver.summaryHash(
            for: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId
        )

        // Move the workspace into the group: only `groupId` changes.
        member.groupId = groupId

        let after = MobileWorkspaceListObserver.summaryHash(
            for: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId
        )
        #expect(before != after, "a pure group-membership move must change the mobile summary hash")
    }

    @Test func reparentingWorkspaceGroupChangesObserverHash() throws {
        let manager = TabManager()
        let parentId = try #require(manager.createWorkspaceGroup(name: "Hotels"))
        let childId = try #require(manager.createWorkspaceGroup(name: "Marriott"))

        let before = MobileWorkspaceListObserver.summaryHash(
            for: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId
        )

        #expect(manager.setWorkspaceGroupParent(groupId: childId, parentGroupId: parentId))

        let after = MobileWorkspaceListObserver.summaryHash(
            for: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId
        )
        #expect(before != after, "a folder reparent must change the mobile summary hash")
    }

    /// A new notification (or clearing the latest one) changes only a workspace's
    /// preview signature, not the tab set, groups, panels, title, or pin state.
    /// The signature must be folded into the summary hash so the observer
    /// re-emits and the phone refreshes the row's preview line + relative time.
    @Test func previewSignatureChangeChangesObserverHash() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)

        let before = MobileWorkspaceListObserver.summaryHash(
            for: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId,
            previewSignatures: [:]
        )
        let after = MobileWorkspaceListObserver.summaryHash(
            for: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId,
            previewSignatures: [workspace.id: 42]
        )
        #expect(before != after, "a preview-signature change must change the mobile summary hash")

        let changed = MobileWorkspaceListObserver.summaryHash(
            for: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId,
            previewSignatures: [workspace.id: 43]
        )
        #expect(after != changed, "a newer notification must change the mobile summary hash")
    }

    /// Why some rows showed no relative time: the payload's only timestamp was
    /// `preview_at`, sourced from the latest notification, so a workspace that
    /// never fired a notification carried no timestamp at all and its trailing
    /// slot stayed empty on the phone. Every workspace payload must carry
    /// `last_activity_at` (the latest notification when there is one, the
    /// workspace's creation time otherwise) so every row can render a time.
    @Test func everyWorkspacePayloadCarriesLastActivity() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)

        // A freshly created workspace has no notification, so it has no preview
        // and previously no timestamp of any kind.
        let payload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: false,
            requestedTerminalID: nil
        )
        #expect(payload["preview_at"] is NSNull, "no notification means no preview timestamp")

        let lastActivity = try #require(
            payload["last_activity_at"] as? Double,
            "a quiet workspace must still carry a last-activity stamp"
        )
        // The fallback is the workspace's creation time: a real, recent instant,
        // never the epoch (which the phone treats as "no activity").
        let now = Date().timeIntervalSince1970
        #expect(lastActivity > now - 3600)
        #expect(lastActivity <= now + 60)
    }

    /// The payload's `has_unread` mirrors the Mac sidebar's workspace unread
    /// badge, and flipping it must also change the observer's per-workspace
    /// signature so the phone is told to refresh (an unread toggle changes
    /// nothing else this observer watches).
    @Test func workspaceUnreadFlagFlowsIntoPayloadAndSignature() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let store = TerminalNotificationStore.shared
        #expect(!store.workspaceIsUnread(forTabId: workspace.id))

        let readPayload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: false,
            requestedTerminalID: nil,
            notificationStore: store
        )
        #expect(readPayload["has_unread"] as? Bool == false)
        let readSignatures = MobileWorkspaceListObserver.previewSignatures(
            for: [workspace],
            notificationStore: store
        )

        #expect(store.setPanelDerivedUnread(true, forTabId: workspace.id))
        defer { store.setPanelDerivedUnread(false, forTabId: workspace.id) }

        let unreadPayload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: false,
            requestedTerminalID: nil,
            notificationStore: store
        )
        #expect(unreadPayload["has_unread"] as? Bool == true)

        let unreadSignatures = MobileWorkspaceListObserver.previewSignatures(
            for: [workspace],
            notificationStore: store
        )
        #expect(
            readSignatures[workspace.id] != unreadSignatures[workspace.id],
            "an unread flip must change the per-workspace signature so the observer re-emits"
        )
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
        // CSI parameter bytes are the full ECMA-48 0x30-0x3F range, not just
        // digits/;/?. Modern 24-bit color uses colon-separated SGR parameters
        // (ESC[38:2::255:0:0m); stripping must consume the whole sequence
        // instead of leaving ":2::255:0:0m" visible in the preview.
        #expect(
            TerminalController.mobilePreviewSanitize("\u{001B}[38:2::255:0:0mred\u{001B}[0m text") ==
                "red text"
        )
        // Same range covers the private-use <=> parameter bytes.
        #expect(TerminalController.mobilePreviewSanitize("\u{001B}[>4;2mok") == "ok")
        // The input bound must hold in unicode scalars, not Characters: a single
        // crafted grapheme cluster carrying a huge run of combining marks is one
        // Character, so a Character-counted cap never truncates it and the whole
        // cluster leaks into the preview (and gets fully scanned on the
        // main-actor list path). The sanitized output must stay scalar-bounded.
        let combiningBomb = "a" + String(
            repeating: "\u{0301}",
            count: TerminalController.mobilePreviewInputCap * 8
        )
        let boundedCluster = try #require(TerminalController.mobilePreviewSanitize(combiningBomb))
        #expect(boundedCluster.unicodeScalars.count <= TerminalController.mobilePreviewInputCap + 1)
        #expect(boundedCluster.hasSuffix("\u{2026}"))
    }
}
