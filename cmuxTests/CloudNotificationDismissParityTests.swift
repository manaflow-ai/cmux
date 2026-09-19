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
        let harness = try ParityHarness()
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
        let harness = try ParityHarness()
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
        let harness = try ParityHarness()
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
        let harness = try ParityHarness()
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
        let harness = try ParityHarness()
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
        let harness = try ParityHarness()
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

    @Test("Clicking the banner reads its row through the store subscription")
    func clickingTheBannerReadsItsRow() async throws {
        let harness = try ParityHarness()
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

/// The two sidebars, the store, and one machine wired the way the app wires
/// them: the shared store, a tab manager with a local workspace bound to the
/// machine's `ws_1` whose focused pane projects `term_a`, a catalog holding the
/// machine's graph (`ws_1`: `term_a`, `term_b`; `ws_2`: `term_c`), the
/// provider's placement resolver and local delivery, and a hub attached to
/// the store with an injectable admission clock.
@MainActor
private final class ParityHarness {
    let machine = SurfaceMachineID.cloud("parity-machine")
    let store: TerminalNotificationStore
    let manager: TabManager
    let workspace: Workspace
    let panelID: UUID
    let catalog: SurfaceCatalog
    let provider: CloudPlacementTestProvider
    let state: CloudVMState
    let defaults: UserDefaults
    let defaultsName: String
    let persistence: CloudNotificationSyncStore
    let hub: CloudNotificationSyncHub
    let clock: AdmissionClock
    private(set) var sync: CloudNotificationSync?
    private var acks: [[String]] = []
    private let restore: @MainActor () -> Void

    final class AdmissionClock {
        var now: UInt64 = 1
    }

    init() throws {
        let store = TerminalNotificationStore.shared
        let defaultsName = "cmux.tests.cloud-dismiss-parity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let clock = AdmissionClock()
        let manager = TabManager()
        self.store = store
        self.defaultsName = defaultsName
        self.defaults = defaults
        self.clock = clock
        self.manager = manager
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = originalAppDelegate ?? AppDelegate()
        let originalTabManager = appDelegate.tabManager
        let originalStore = appDelegate.notificationStore
        let originalFocus = AppFocusState.overrideIsFocused
        let originalObserver = store.readTargetObserver
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        if AppDelegate.shared == nil { AppDelegate.shared = appDelegate }
        AppFocusState.overrideIsFocused = false
        restore = {
            for workspace in manager.tabs { manager.closeWorkspace(workspace) }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            store.readTargetObserver = originalObserver
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalStore
            AppDelegate.shared = originalAppDelegate
            AppFocusState.overrideIsFocused = originalFocus
            defaults.removePersistentDomain(forName: defaultsName)
        }

        workspace = try #require(manager.selectedWorkspace)
        panelID = try #require(workspace.focusedPanelId)
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "ws_1")

        catalog = SurfaceCatalog()
        provider = CloudPlacementTestProvider(machine: machine)
        state = try Self.graph(machine: machine)
        let info = SurfaceMachineInfo(
            id: machine, name: "Fixture", status: "running", image: nil, hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            remoteWorkspaces: state.workspaces.map {
                SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
            }
        )
        provider.info = info
        catalog.register(provider)
        catalog.replaceCloudState(state, resources: CmuxTuiSnapshotParser.resources(from: state), info: info)
        catalog.record(SurfaceProjection(
            resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_a"),
            workspaceID: workspace.id, panelID: panelID, remoteWorkspaceID: "ws_1", remoteTabID: "tab_a"
        ))

        persistence = CloudNotificationSyncStore(defaults: defaults)
        hub = CloudNotificationSyncHub(
            persistenceStore: persistence,
            gate: CloudMachineNotificationGate(now: { clock.now })
        )
        hub.attach(store: store)
        rebuildSync()
    }

    func close() {
        sync?.retire()
        hub.unregister(machineID: machine.rawValue)
        restore()
    }

    // MARK: Machine graph

    private static func graph(machine: SurfaceMachineID) throws -> CloudVMState {
        func tab(_ key: String, pane: String, index: Int) -> [String: Any] {
            ["id": "tab_\(key)", "pane_id": pane, "index": index, "focused": index == 0,
             "name": "", "content_kind": "terminal", "content_id": "term_\(key)"]
        }
        let document: [String: Any] = [
            "cursor": ["generation": "fixture", "revision": "1"],
            "workspaces": [
                ["id": "ws_1", "name": "issue-1", "index": 0, "focused": true],
                ["id": "ws_2", "name": "issue-2", "index": 1, "focused": false],
            ],
            "screens": [
                ["id": "screen_1", "workspace_id": "ws_1", "layout": [
                    "version": 1, "screen_id": "screen_1",
                    "root": ["kind": "leaf", "pane_id": "pane_1", "tab_ids": ["tab_a", "tab_b"]],
                ]],
                ["id": "screen_2", "workspace_id": "ws_2", "layout": [
                    "version": 1, "screen_id": "screen_2",
                    "root": ["kind": "leaf", "pane_id": "pane_2", "tab_ids": ["tab_c"]],
                ]],
            ],
            "panes": [["id": "pane_1", "screen_id": "screen_1"], ["id": "pane_2", "screen_id": "screen_2"]],
            "tabs": [tab("a", pane: "pane_1", index: 0), tab("b", pane: "pane_1", index: 1), tab("c", pane: "pane_2", index: 0)],
            "terminals": ["a", "b", "c"].map { ["id": "term_\($0)", "title": "agent \($0)", "lifecycle": "running"] },
            "browsers": [], "agents": [],
        ]
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
    }

    func row(_ id: String, terminal: String, title: String, createdAt: UInt64) -> CloudVMNotificationRow {
        CloudVMNotificationRow(
            id: "notification_\(id)", title: title, subtitle: nil, body: "", level: "info",
            createdAtMs: createdAt, terminalID: terminal, readBy: []
        )
    }

    // MARK: Sync lifecycle

    /// The provider's placement resolver and local delivery over this fixture.
    private func makeSync() -> CloudNotificationSync {
        let resolver = CloudNotificationPlacementResolver(
            machine: machine,
            projections: { [catalog] in catalog.projections(of: $0) },
            remoteWorkspaceID: { [state] terminalID in
                for tab in state.tabs where tab.contentID == terminalID {
                    guard let pane = state.lookupIndex.pane(id: tab.paneID),
                          let screen = state.lookupIndex.screen(id: pane.screenID) else { continue }
                    return screen.workspaceID
                }
                return nil
            },
            boundWorkspaces: { [manager, machine] in
                manager.tabs.compactMap { workspace in
                    guard let binding = workspace.cloudVMBinding, binding.vmID == machine.rawValue else { return nil }
                    return CloudNotificationBoundWorkspace(workspaceID: workspace.id, remoteWorkspaceID: binding.remoteWorkspaceID)
                }
            }
        )
        let delivery = CloudNotificationLocalDelivery(
            machineID: machine.rawValue,
            store: { [store] in store },
            admit: { [hub, machine] in hub.admit($0, machineID: machine.rawValue) },
            machineName: { "Fixture" },
            terminalTitle: { [state] in state.lookupIndex.terminal(id: $0)?.title }
        )
        let machineID = machine.rawValue
        let hub = hub
        return CloudNotificationSync(
            machineID: machineID,
            clientID: "mac-parity",
            store: persistence,
            resolveTarget: { resolver.target(for: $0) },
            deliver: { delivery.deliver($0, to: $1) },
            send: { [weak self] batch in self?.acks.append(batch.ids) },
            unreadChanged: { hub.setUnread($0, machineID: machineID) },
            withdraw: { [store] ids in
                let removed = Set(ids)
                for notification in store.notifications where notification.correlationKey.map({
                    CloudNotificationCorrelation.matches($0, machineID: machineID, notificationIDs: removed)
                }) == true {
                    store.remove(id: notification.id)
                }
            }
        )
    }

    /// A fresh sync from the durable state, as a provider rebuild does.
    func rebuildSync() {
        sync?.retire()
        let next = makeSync()
        sync = next
        hub.register(next)
    }

    /// The provider is suspended: its sync retires and leaves the hub.
    func suspendSync() {
        sync?.retire()
        sync = nil
        hub.unregister(machineID: machine.rawValue)
    }

    func apply(_ rows: [CloudVMNotificationRow]) {
        sync?.apply(rows: rows)
    }

    func flush() async {
        await sync?.flushPendingReads()
    }

    var ackedIDs: Set<String> { Set(acks.flatMap { $0 }) }

    /// The hub observes the store's `$notifications` publication on the main
    /// run loop. Runs that loop until `predicate` holds; the deadline bounds
    /// only the failure path.
    func spinStoreSubscription(until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: Indicators

    /// The left sidebar's badge for the bound workspace, from the coalesced
    /// sidebar projection the workspace rows render.
    var leftBadge: Int {
        store.sidebarUnread.summaryByWorkspaceId[workspace.id]?.unreadCount ?? 0
    }

    /// Cloud tree rows carrying the attention dot, built from the catalog and
    /// the hub's unread index exactly as the Machines panel builds them.
    func treeDots() -> Set<String> {
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: catalog.snapshot, localWorkspaces: [],
            unreadTerminalIDs: hub.unreadTerminalIDs, includeLocalMachine: false
        )
        var dots = Set<String>()
        for node in CloudTreeNodeBuilder.flattened(nodes) where node.hasUnreadAttention {
            switch node.kind {
            case .terminal(let row):
                dots.insert(row.resource.id.key)
            case .workspace:
                for id in ["ws_1", "ws_2"] where node.id == CloudTreeNodeBuilder.nodeID(workspace: id, machine: machine) {
                    dots.insert(id)
                }
            default:
                dots.insert(node.id)
            }
        }
        return dots
    }

    /// Every indicator for the workspace and the given terminals reports read.
    func expectEverythingRead(terminals: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let recordsRead = store.notifications.allSatisfy(\.isRead)
        #expect(recordsRead, "store records", sourceLocation: sourceLocation)
        #expect(leftBadge == 0, "left sidebar badge", sourceLocation: sourceLocation)
        #expect(store.unreadCount(forTabId: workspace.id) == 0, "workspace unread count", sourceLocation: sourceLocation)
        #expect(!store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelID), "pane ring", sourceLocation: sourceLocation)
        #expect(hub.unreadTerminalIDs[machine.rawValue] == nil, "hub unread index", sourceLocation: sourceLocation)
        #expect(sync?.unreadTerminalIDs.isEmpty == true, "sync unread set", sourceLocation: sourceLocation)
        #expect(treeDots().isEmpty, "Cloud tree dots \(treeDots()) for \(terminals)", sourceLocation: sourceLocation)
    }
}
