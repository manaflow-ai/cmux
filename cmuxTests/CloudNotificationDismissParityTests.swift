import AppKit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// One read state per Cloud notification (manaflow-ai/cmux#13000). Rows come
/// off a machine's daemon feed, become local records through the provider's
/// own placement and delivery pieces, and every dismissal path the app
/// exposes must clear every indicator at once: the local record, the left
/// sidebar's per-workspace summary, the pane ring, and the Cloud tree's
/// workspace and terminal rows, including after the daemon replays a stale
/// snapshot and after the machine's sync is rebuilt from durable state.
@Suite("Cloud notification dismiss parity", .serialized)
@MainActor
struct CloudNotificationDismissParityTests {
    @Test("Clicking into the pane clears the ring and the Cloud tree dot, even with a deduplicated repeat row")
    func paneFocusClearsTheCloudTreeDot() async throws {
        let harness = try CloudNotificationDismissParityHarness()
        defer { harness.close() }
        let first = harness.row("finished-1", terminal: "term_a", title: "Codex finished", createdAt: 1)
        // Same terminal, same text, one second later: the admission gate's
        // identical-content window drops it, exactly like a hook that fires
        // twice for one completion.
        let repeat_ = harness.row("finished-2", terminal: "term_a", title: "Codex finished", createdAt: 2)
        harness.apply([first, repeat_])

        #expect(harness.store.notifications.filter { !$0.isRead }.count == 1)
        #expect(harness.leftBadge == 1)
        #expect(harness.store.hasVisibleNotificationIndicator(forTabId: harness.workspace.id, surfaceId: harness.panelID))
        #expect(harness.treeDots() == ["ws_1", "term_a"])

        // The user clicks into the pane.
        #expect(harness.manager.dismissNotificationOnDirectInteraction(tabId: harness.workspace.id, surfaceId: harness.panelID))

        harness.expectEverythingRead(terminals: ["term_a"])
        await harness.flush()
        #expect(harness.ackedIDs == Set([first.id, repeat_.id]), "both rows are acknowledged to the machine")

        // A stale snapshot from the daemon still carries both rows as unread.
        harness.apply([first, repeat_])
        harness.expectEverythingRead(terminals: ["term_a"])

        // The provider is rebuilt (sleep, feature toggle, relaunch) from the
        // durable state and folds the same rows again.
        harness.rebuildSync()
        harness.apply([first, repeat_])
        harness.expectEverythingRead(terminals: ["term_a"])
        #expect(harness.store.notifications.count == 1, "nothing was delivered twice")
    }

    @Test("Visiting the workspace reads a row placed at the workspace level (no pane shows its terminal)")
    func visitingTheWorkspaceReadsWorkspaceLevelRows() async throws {
        let harness = try CloudNotificationDismissParityHarness()
        defer { harness.close() }
        AppFocusState.overrideIsFocused = true
        let row = harness.row("b-1", terminal: "term_b", title: "Claude finished", createdAt: 1)
        harness.apply([row])
        let record = try #require(harness.store.notifications.first)
        #expect(record.tabId == harness.workspace.id)
        #expect(record.surfaceId == nil, "term_b is not projected here, so the row lands on the workspace")
        #expect(harness.leftBadge == 1)
        #expect(harness.treeDots() == ["ws_1", "term_b"])

        // Workspace selection's side effect: the focused pane and, since
        // manaflow-ai/cmux#12387, the workspace level are dismissed.
        harness.manager.notificationDismissal.dismissFocusedPanelNotificationIfActive(
            workspaceId: harness.workspace.id, context: .explicitWorkspaceResume
        )

        harness.expectEverythingRead(terminals: ["term_b"])
        await harness.flush()
        #expect(harness.ackedIDs == [row.id])
    }

    @Test("A remote workspace with no local workspace keeps its dot but never stacks onto another workspace's badge")
    func unopenedRemoteWorkspaceRowsStayOffTheLocalBadge() async throws {
        let harness = try CloudNotificationDismissParityHarness()
        defer { harness.close() }
        let row = harness.row("c-1", terminal: "term_c", title: "Codex finished", createdAt: 1)
        harness.apply([row])

        #expect(harness.store.notifications.isEmpty, "no local home for ws_2 yet")
        #expect(harness.leftBadge == 0, "the bound workspace's badge counts only its own remote workspace")
        #expect(harness.treeDots() == ["ws_2", "term_c"])

        // Opening ws_2 locally gives the row its home on the next fold.
        let opened = harness.manager.addWorkspace(select: false)
        opened.cloudVMBinding = WorkspaceCloudVMBinding(vmID: harness.machine.rawValue, isBase: false, remoteWorkspaceID: "ws_2")
        harness.apply([row])
        #expect(harness.store.notifications.map(\.tabId) == [opened.id])
        #expect(harness.leftBadge == 0)
        #expect(harness.store.unreadCount(forTabId: opened.id) == 1)
        #expect(harness.treeDots() == ["ws_2", "term_c"])

        // Mark all read clears the machine too.
        harness.store.markAllRead()
        harness.expectEverythingRead(terminals: ["term_c"])
        #expect(harness.store.unreadCount(forTabId: opened.id) == 0)
        await harness.flush()
        #expect(harness.ackedIDs == [row.id])
        harness.manager.closeWorkspace(opened)
    }

    @Test("Rows over the admission rate are delivered on a later fold instead of leaving an undismissable dot")
    func rateLimitedRowsAreThrottledNotLost() async throws {
        let harness = try CloudNotificationDismissParityHarness()
        defer { harness.close() }
        let rows = (1...7).map { harness.row("burst-\($0)", terminal: "term_a", title: "finished \($0)", createdAt: UInt64($0)) }
        harness.apply(rows)
        #expect(harness.store.notifications.count == 5, "the machine budget admits five in one tick")
        #expect(harness.treeDots() == ["ws_1", "term_a"])

        // Two seconds later the bucket has refilled and the next fold delivers the rest.
        harness.clock.now += 2_000_000_000
        harness.apply(rows)
        #expect(harness.store.notifications.count == 7)
        #expect(harness.leftBadge == 7)

        #expect(harness.manager.dismissNotificationOnDirectInteraction(tabId: harness.workspace.id, surfaceId: harness.panelID))
        harness.expectEverythingRead(terminals: ["term_a"])
        await harness.flush()
        #expect(harness.ackedIDs == Set(rows.map(\.id)))
    }

    @Test("A dismissal while the machine's sync is gone is acknowledged when the sync comes back")
    func dismissalWhileTheSyncIsGoneSurvivesRestore() async throws {
        let harness = try CloudNotificationDismissParityHarness()
        defer { harness.close() }
        let row = harness.row("asleep-1", terminal: "term_a", title: "Codex finished", createdAt: 1)
        harness.apply([row])
        #expect(harness.treeDots() == ["ws_1", "term_a"])

        // The provider is suspended (feature flag off, machine asleep) before the user reads it.
        harness.suspendSync()
        #expect(harness.treeDots().isEmpty, "a suspended machine shows no dots")
        #expect(harness.manager.dismissNotificationOnDirectInteraction(tabId: harness.workspace.id, surfaceId: harness.panelID))
        let recordsRead = harness.store.notifications.allSatisfy(\.isRead)
        #expect(recordsRead)
        // The store subscription writes the read into the machine's durable
        // state, since no sync is live to take it.
        harness.spinStoreSubscription { !harness.persistence.load(machineID: harness.machine.rawValue).pendingAcks.isEmpty }
        #expect(!harness.persistence.load(machineID: harness.machine.rawValue).pendingAcks.isEmpty)

        harness.rebuildSync()
        harness.apply([row])
        harness.expectEverythingRead(terminals: ["term_a"])
        await harness.flush()
        #expect(harness.ackedIDs == [row.id], "the read taken while the sync was gone still reaches the machine")
    }

    @Test("`cmux notify --clear` on the pane clears every indicator, including a deduplicated repeat row")
    func clearThroughTheSocketPathClearsEverything() async throws {
        let harness = try CloudNotificationDismissParityHarness()
        defer { harness.close() }
        let first = harness.row("clear-1", terminal: "term_a", title: "Build done", createdAt: 1)
        let repeat_ = harness.row("clear-2", terminal: "term_a", title: "Build done", createdAt: 2)
        harness.apply([first, repeat_])
        #expect(harness.leftBadge == 1)

        // The socket `clear_notifications` handler's store call.
        harness.store.clearNotifications(forTabId: harness.workspace.id, surfaceId: harness.panelID)

        #expect(harness.store.notifications.isEmpty)
        harness.expectEverythingRead(terminals: ["term_a"])
        await harness.flush()
        #expect(harness.ackedIDs == Set([first.id, repeat_.id]))
    }

    @Test("A muted workspace reads its rows at once instead of leaving a dot nothing can dismiss")
    func mutedWorkspaceRowsAreReadNotStranded() async throws {
        let harness = try CloudNotificationDismissParityHarness()
        defer { harness.close() }
        harness.workspace.isMuted = true
        let row = harness.row("muted-1", terminal: "term_a", title: "Codex finished", createdAt: 1)
        harness.apply([row])

        #expect(harness.store.notifications.isEmpty, "mute admits nothing locally")
        harness.expectEverythingRead(terminals: ["term_a"])
        await harness.flush()
        #expect(harness.ackedIDs == [row.id], "the machine learns this client will never show it")
    }

    @Test("A terminal the graph places in no workspace fails closed instead of badging an unrelated workspace")
    func unmappedTerminalRowsHaveNoLocalHome() async throws {
        let harness = try CloudNotificationDismissParityHarness()
        defer { harness.close() }
        // The daemon knows the terminal but no tab shows it.
        let row = harness.row("detached-1", terminal: "term_detached", title: "Build done", createdAt: 1)
        harness.apply([row])

        #expect(harness.store.notifications.isEmpty)
        #expect(harness.leftBadge == 0)
        #expect(harness.hub.unreadTerminalIDs[harness.machine.rawValue] == ["term_detached"], "the row stays unread on the machine side")
        // Nothing consumed it: a later fold with a placement delivers it.
        harness.catalog.record(SurfaceProjection(
            resource: SurfaceResourceID(machine: harness.machine, kind: .terminal, key: "term_detached"),
            workspaceID: harness.workspace.id, panelID: harness.panelID, remoteWorkspaceID: "ws_1", remoteTabID: "tab_d"
        ))
        harness.apply([row])
        #expect(harness.store.notifications.count == 1)
        #expect(harness.leftBadge == 1)
    }

    @Test("Clicking the banner reads its row through the store subscription")
    func clickingTheBannerReadsItsRow() async throws {
        let harness = try CloudNotificationDismissParityHarness()
        defer { harness.close() }
        let row = harness.row("click-1", terminal: "term_a", title: "Codex finished", createdAt: 1)
        harness.apply([row])
        let record = try #require(harness.store.notifications.first)

        harness.store.markRead(id: record.id)
        harness.spinStoreSubscription { harness.hub.unreadTerminalIDs[harness.machine.rawValue] == nil }

        harness.expectEverythingRead(terminals: ["term_a"])
        await harness.flush()
        #expect(harness.ackedIDs == [row.id])
    }
}
