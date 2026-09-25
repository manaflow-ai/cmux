import AppKit
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The two sidebars, the store, and one machine wired the way the app wires
/// them: the shared store, a tab manager with a local workspace bound to the
/// machine's `ws_1` whose focused pane projects `term_a`, a catalog holding the
/// machine's graph (`ws_1`: `term_a`, `term_b`; `ws_2`: `term_c`), the
/// provider's placement resolver and local delivery, and a hub attached to
/// the store with an injectable admission clock.
@MainActor
final class CloudNotificationDismissParityHarness {
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
