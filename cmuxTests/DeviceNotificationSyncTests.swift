import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxCloud
import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux notify` in a terminal on another Mac under My Devices must reach this
/// Mac: the link follows the other Mac's notification feed, each row lands on
/// the pane mirroring its terminal, the Devices tree shows the unread dot, and
/// a record this Mac mirrored is never served back to a peer.
@MainActor
@Suite("Devices: notification sync")
struct DeviceNotificationSyncTests {
    private let instance = SurfaceDeviceInstanceID(deviceID: "3f2504e0-4f89-11d3-9a0c-0305e82c3301", tag: "nightly")
    private var machine: SurfaceMachineID { .device(instance) }

    @Test func feedReplyBecomesSyncRowsAndSkipsRelayedOrigins() throws {
        let terminal = UUID()
        let workspace = UUID().uuidString
        let feed = DeviceNotificationFeed(response: [
            "revision": 7,
            "notifications": [
                // Newest first, as the host serves it.
                ["id": "B", "workspace_id": workspace, "surface_id": terminal.uuidString.lowercased(),
                 "title": "Done", "subtitle": "", "body": "Codex finished", "created_at": 20.5,
                 "is_read": false, "origin_kind": "local"],
                ["id": "A", "workspace_id": workspace, "title": "Old", "subtitle": "sub", "body": "",
                 "created_at": 10.0, "is_read": true],
                ["id": "C", "workspace_id": workspace, "title": "VM", "body": "", "created_at": 30.0,
                 "is_read": false, "origin_kind": "cloud-vm"],
                ["id": "D", "workspace_id": workspace, "title": "Third Mac", "body": "", "created_at": 40.0,
                 "is_read": false, "origin_kind": "device-mac"],
            ],
        ])
        #expect(feed.rows.map(\.id) == ["A", "B"])
        let unread = try #require(feed.rows.last)
        #expect(unread.terminalID == terminal.uuidString)
        #expect(unread.createdAtMs == 20_500)
        #expect(unread.body == "Codex finished")
        #expect(unread.subtitle == nil)
        #expect(!unread.isRead(by: DeviceNotificationFeed.clientID))
        let read = try #require(feed.rows.first)
        #expect(read.isRead(by: DeviceNotificationFeed.clientID))
        #expect(read.terminalID == nil)
        #expect(read.subtitle == "sub")
        #expect(feed.remoteWorkspaceIDs == ["A": workspace, "B": workspace])
    }

    @Test func deviceOriginRoundTripsForHooks() {
        let origin = TerminalNotificationOrigin.deviceMac(machineID: machine.rawValue)
        #expect(origin.kind == "device-mac")
        #expect(origin.isRemote)
        #expect(origin.wireValue == "device-mac:" + machine.rawValue)
        #expect(TerminalNotificationOrigin(wireValue: origin.wireValue) == origin)
        #expect(TerminalNotificationOrigin(wireValue: "device-mac:") == .local)
        #expect(TerminalNotificationPolicyOriginContext(origin).machine == machine.rawValue)
    }

    @Test func hostFeedOmitsRecordsMirroredFromAnotherMac() {
        func record(_ origin: TerminalNotificationOrigin?) -> NotificationFeedHistoryRecord {
            NotificationFeedHistoryRecord(id: UUID(), tabId: UUID(), surfaceId: nil, panelId: nil,
                retargetsToLiveSurfaceOwner: false, title: "t", subtitle: "", body: "", createdAt: Date(),
                isRead: false, origin: origin)
        }
        #expect(TerminalController.isMirroredFromDevice(record(.deviceMac(machineID: machine.rawValue))))
        #expect(!TerminalController.isMirroredFromDevice(record(nil)))
        #expect(!TerminalController.isMirroredFromDevice(record(.cloudVM(machineID: "vivid-newt"))))
    }

    @Test func linkSubscribesToTheNotificationFeed() {
        #expect(DeviceLink.eventTopics.contains(DeviceLink.notificationFeedTopic))
    }

    @Test func providerSyncsFeedRowsOntoTheMirroringPane() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let viewer = try #require(manager.selectedWorkspace)
        let panel = try #require(viewer.focusedPanelId)
        defer { viewer.teardownAllPanels(); manager.tabs = [] }
        let remoteTerminal = UUID().uuidString
        let remoteWorkspaceID = UUID().uuidString
        let live = LiveWorkspaceFixture()
        live.register(viewer)
        let catalog = SurfaceCatalog(live: live)
        let defaultsName = "DeviceNotificationSync-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let record = DeviceDirectoryRecord(instance: instance, deviceName: "Mac mini", platform: "mac",
            bundleID: nil, presenceState: .online, isPaired: false, lastSeenAt: nil, routes: [],
            ownerUserID: "test", accountTrust: .sameAccount)
        let link = DeviceLink(record: record, runtime: DeviceLinkRuntime(tokens: HiveAccountTokenSource(
            auth: makeAuth(defaults: defaults), identity: AuthenticatedSessionIdentity(generation: 0, accountID: "test"), teamID: nil
        )), authorization: UnpairedAuthorization())
        let provider = DeviceSurfaceProvider(record: record, link: link, catalog: catalog)
        defer { provider.stop() }
        catalog.register(provider)

        let sync = try #require(provider.notificationSync)
        #expect(CloudNotificationSyncHub.shared.sync(machineID: machine.rawValue) === sync)

        let remoteWorkspace = SurfaceRemoteWorkspace(id: remoteWorkspaceID, name: "cmux-browser-hq", index: 0, focused: true)
        let resource = SurfaceResource(id: .init(machine: machine, kind: .terminal, key: remoteTerminal),
            title: "zsh", detail: nil, lifecycle: .running, agent: nil, remoteWorkspace: remoteWorkspace,
            remoteViews: [SurfaceRemoteView(tabID: remoteTerminal, workspace: remoteWorkspace)], port: nil, url: nil)
        catalog.upsert(resource)
        catalog.record(.init(resource: resource.id, workspaceID: viewer.id, panelID: panel,
            remoteWorkspaceID: remoteWorkspaceID, remoteTabID: remoteTerminal))

        provider.notificationFeed = DeviceNotificationFeed(response: ["notifications": [
            ["id": UUID().uuidString, "workspace_id": remoteWorkspaceID, "surface_id": remoteTerminal,
             "title": "cmux", "body": "Notification", "created_at": 1.0, "is_read": false],
        ]])
        let row = try #require(provider.notificationFeed.rows.first)
        #expect(provider.notificationDeliveryTarget(for: row) == CloudNotificationDeliveryTarget(workspaceID: viewer.id, panelID: panel))

        provider.stop()
        #expect(CloudNotificationSyncHub.shared.sync(machineID: machine.rawValue) == nil)
    }

    @Test func devicesTreeShowsTheUnreadDotForADeviceTerminal() throws {
        let workspace = SurfaceRemoteWorkspace(id: "ws_1", name: "cmux-browser-hq", index: 0, focused: true)
        let terminal = UUID().uuidString
        var resource = SurfaceResource(id: SurfaceResourceID(machine: machine, kind: .terminal, key: terminal),
            title: "zsh", detail: "~", lifecycle: .running, agent: nil, remoteWorkspace: workspace, port: nil, url: nil)
        resource.remoteViews = [SurfaceRemoteView(tabID: terminal, workspace: workspace)]
        let snapshot = SurfaceCatalogSnapshot(machines: [SurfaceMachineInfo(
            id: machine, name: "Mac mini", status: "running", image: nil, hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil, remoteWorkspaces: [workspace],
            presence: SurfaceDevicePresence(state: .online, lastSeenAt: nil, tag: instance.tag,
                bundleID: "com.cmuxterm.app", accountTrust: .sameAccount)
        )], resources: [resource], projections: [])
        let nodes = CloudTreeNodeBuilder.nodes(machines: [], snapshot: snapshot, localWorkspaces: [],
            unreadTerminalIDs: [machine.rawValue: [terminal]], includeLocalMachine: false, source: .devices)
        let rows = CloudTreeNodeBuilder.flattened(nodes).compactMap { node -> Bool? in
            if case .terminal(let row) = node.kind { return row.hasUnreadNotification }
            return nil
        }
        // The terminal renders under its workspace and in the Terminals pool.
        #expect(!rows.isEmpty && rows.allSatisfy { $0 })
        let quiet = CloudTreeNodeBuilder.nodes(machines: [], snapshot: snapshot, localWorkspaces: [],
            unreadTerminalIDs: [:], includeLocalMachine: false, source: .devices)
        let quietRows = CloudTreeNodeBuilder.flattened(quiet).compactMap { node -> Bool? in
            if case .terminal(let row) = node.kind { return row.hasUnreadNotification }
            return nil
        }
        #expect(quietRows.count == rows.count && quietRows.allSatisfy { !$0 })
    }

    private func makeAuth(defaults: UserDefaults) -> AuthCoordinator {
        let config = AuthConfig(stack: CMUXAuthConfig(projectId: "test", publishableClientKey: "test"),
            magicLinkCallbackURL: "http://127.0.0.1:1/auth/callback", apiBaseURL: "http://127.0.0.1:1")
        return AuthCoordinator(
            client: StackAuthClient(config: config, tokenStore: .memory, noAutomaticPrefetch: true),
            sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "session"),
            userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "team"),
            anchor: AuthPresentationContextProvider(), config: config,
            launch: AuthLaunchOptions(clearAuthRequested: false, mockDataEnabled: false, environment: [:], includesDevAuth: false))
    }

    private final class UnpairedAuthorization: DeviceLinkAuthorizationSource {
        var pairedDevices: [DevicePairedDevice] { [] }
        let authorizationDidChangeNotification = Notification.Name("DeviceNotificationSync-\(UUID().uuidString)")
        func authorization(for instance: SurfaceDeviceInstanceID, route: CmxAttachRoute) -> CmxLegacyTailscaleAuthorizationEvidence? { nil }
    }
}
