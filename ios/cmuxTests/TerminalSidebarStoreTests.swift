import Combine
import XCTest
@testable import cmux_DEV

final class TerminalSidebarStoreTests: XCTestCase {
    @MainActor
    func testInitialStateSeedsPinnedHostsAndNoWorkspaces() {
        let store = makeStore().store

        XCTAssertFalse(store.hosts.isEmpty)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNil(store.selectedWorkspaceID)
    }

    @MainActor
    func testStartWorkspaceSelectsAndPersistsNewWorkspace() throws {
        let fixture = makeStore()
        let store = fixture.store
        let host = try XCTUnwrap(store.hosts.first)

        let workspaceID = store.startWorkspace(on: host)

        let workspace = try XCTUnwrap(store.workspace(with: workspaceID))
        XCTAssertEqual(store.selectedWorkspaceID, workspaceID)
        XCTAssertEqual(store.workspaces.first?.id, workspaceID)
        XCTAssertEqual(workspace.hostID, host.id)
        XCTAssertTrue(workspace.tmuxSessionName.hasPrefix("cmux-"))
        XCTAssertEqual(fixture.snapshotStore.load().workspaces.first?.id, workspaceID)
    }

    @MainActor
    func testStartWorkspaceReservesAndPersistsBackendIdentityForTeamHost() async throws {
        let host = TerminalHost(
            stableID: "cmux-macmini",
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: "team_doc_1",
            serverID: "cmux-macmini"
        )
        let identity = TerminalWorkspaceBackendIdentity(
            teamID: "team_doc_1",
            taskID: "task_doc_1",
            taskRunID: "task_run_doc_1",
            workspaceName: "macmini-101a",
            descriptor: "Mac Mini #101a"
        )
        let fixture = makeStore(
            snapshot: TerminalStoreSnapshot(hosts: [host], workspaces: [], selectedWorkspaceID: nil),
            workspaceIdentityService: StubTerminalWorkspaceIdentityService(identity: identity)
        )

        let workspaceID = fixture.store.startWorkspace(on: host)

        try await waitForCondition {
            fixture.store.workspace(with: workspaceID)?.backendIdentity == identity
        }

        XCTAssertEqual(fixture.store.workspace(with: workspaceID)?.backendIdentity, identity)
        XCTAssertEqual(fixture.snapshotStore.load().workspaces.first?.backendIdentity, identity)
        XCTAssertEqual(fixture.identityService?.recordedHostIDs, [host.id])
    }

    @MainActor
    func testOpenWorkspaceReservesBackendIdentityForLegacyTeamWorkspace() async throws {
        let host = TerminalHost(
            stableID: "cmux-macmini",
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: "team_doc_1",
            serverID: "cmux-macmini"
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-macmini"
        )
        let identity = TerminalWorkspaceBackendIdentity(
            teamID: "team_doc_1",
            taskID: "task_doc_2",
            taskRunID: "task_run_doc_2",
            workspaceName: "macmini-101b",
            descriptor: "Mac Mini #101b"
        )
        let fixture = makeStore(
            snapshot: TerminalStoreSnapshot(
                hosts: [host],
                workspaces: [workspace],
                selectedWorkspaceID: nil
            ),
            workspaceIdentityService: StubTerminalWorkspaceIdentityService(identity: identity)
        )

        _ = fixture.store.openWorkspace(workspace)

        try await waitForCondition {
            fixture.store.workspace(with: workspace.id)?.backendIdentity == identity
        }

        XCTAssertEqual(fixture.store.workspace(with: workspace.id)?.backendIdentity, identity)
        XCTAssertEqual(fixture.identityService?.recordedHostIDs, [host.id])
    }

    @MainActor
    func testOpenWorkspaceDoesNotReReserveExistingBackendIdentity() async throws {
        let host = TerminalHost(
            stableID: "cmux-macmini",
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: "team_doc_1",
            serverID: "cmux-macmini"
        )
        let identity = TerminalWorkspaceBackendIdentity(
            teamID: "team_doc_1",
            taskID: "task_doc_3",
            taskRunID: "task_run_doc_3",
            workspaceName: "macmini-101c",
            descriptor: "Mac Mini #101c"
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-macmini",
            backendIdentity: identity
        )
        let fixture = makeStore(
            snapshot: TerminalStoreSnapshot(
                hosts: [host],
                workspaces: [workspace],
                selectedWorkspaceID: nil
            ),
            workspaceIdentityService: StubTerminalWorkspaceIdentityService(
                identity: TerminalWorkspaceBackendIdentity(
                    teamID: "team_doc_1",
                    taskID: "task_doc_4",
                    taskRunID: "task_run_doc_4",
                    workspaceName: "unused",
                    descriptor: "Unused"
                )
            )
        )

        _ = fixture.store.openWorkspace(workspace)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(fixture.store.workspace(with: workspace.id)?.backendIdentity, identity)
        XCTAssertTrue(fixture.identityService?.recordedHostIDs.isEmpty ?? false)
    }

    @MainActor
    func testOpenWorkspacePersistsBackendMetadataPreviewForLinkedWorkspace() async throws {
        let host = TerminalHost(
            stableID: "cmux-macmini",
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: "team_doc_1",
            serverID: "cmux-macmini"
        )
        let identity = TerminalWorkspaceBackendIdentity(
            teamID: "team_doc_1",
            taskID: "task_doc_5",
            taskRunID: "task_run_doc_5",
            workspaceName: "macmini-101d",
            descriptor: "Mac Mini #101d"
        )
        let metadata = TerminalWorkspaceBackendMetadata(preview: "feature/direct-daemon")
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-macmini",
            backendIdentity: identity
        )
        let fixture = makeStore(
            snapshot: TerminalStoreSnapshot(
                hosts: [host],
                workspaces: [workspace],
                selectedWorkspaceID: nil
            ),
            workspaceMetadataService: StubTerminalWorkspaceMetadataService()
        )

        _ = fixture.store.openWorkspace(workspace)
        fixture.metadataService?.send(metadata, for: identity)

        try await waitForCondition {
            fixture.store.workspace(with: workspace.id)?.backendMetadata == metadata
        }

        XCTAssertEqual(fixture.store.workspace(with: workspace.id)?.backendMetadata, metadata)
        XCTAssertEqual(fixture.snapshotStore.load().workspaces.first?.backendMetadata, metadata)
    }

    @MainActor
    func testApplyDiscoveredHostsBackfillsBackendIdentityAndMetadataForExistingWorkspace() async throws {
        let localHost = TerminalHost(
            stableID: "cmux-macmini",
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon
        )
        let discoveredHost = TerminalHost(
            stableID: "cmux-macmini",
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: "team_doc_6",
            serverID: "cmux-macmini"
        )
        let workspace = TerminalWorkspace(
            hostID: localHost.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-macmini"
        )
        let identity = TerminalWorkspaceBackendIdentity(
            teamID: "team_doc_6",
            taskID: "task_doc_6",
            taskRunID: "task_run_doc_6",
            workspaceName: "macmini-101e",
            descriptor: "Mac Mini #101e"
        )
        let metadata = TerminalWorkspaceBackendMetadata(preview: "feature/identity-backfill")
        let fixture = makeStore(
            snapshot: TerminalStoreSnapshot(
                hosts: [localHost],
                workspaces: [workspace],
                selectedWorkspaceID: nil
            ),
            workspaceIdentityService: StubTerminalWorkspaceIdentityService(identity: identity),
            workspaceMetadataService: StubTerminalWorkspaceMetadataService()
        )

        fixture.store.applyDiscoveredHosts([discoveredHost])

        try await waitForCondition {
            fixture.store.workspace(with: workspace.id)?.backendIdentity == identity
        }

        fixture.metadataService?.send(metadata, for: identity)

        try await waitForCondition {
            fixture.store.workspace(with: workspace.id)?.backendMetadata == metadata
        }

        XCTAssertEqual(fixture.store.workspace(with: workspace.id)?.backendIdentity, identity)
        XCTAssertEqual(fixture.store.workspace(with: workspace.id)?.backendMetadata, metadata)
        XCTAssertEqual(fixture.snapshotStore.load().workspaces.first?.backendIdentity, identity)
        XCTAssertEqual(fixture.snapshotStore.load().workspaces.first?.backendMetadata, metadata)
        XCTAssertEqual(fixture.identityService?.recordedHostIDs, [localHost.id])
    }

    @MainActor
    func testApplyDiscoveredHostsReplacesStaleBackendIdentityWhenTeamScopeChanges() async throws {
        let localHost = TerminalHost(
            stableID: "cmux-macmini",
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: "team_doc_old",
            serverID: "cmux-macmini"
        )
        let discoveredHost = TerminalHost(
            stableID: "cmux-macmini",
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: "team_doc_new",
            serverID: "cmux-macmini"
        )
        let oldIdentity = TerminalWorkspaceBackendIdentity(
            teamID: "team_doc_old",
            taskID: "task_doc_old",
            taskRunID: "task_run_doc_old",
            workspaceName: "macmini-old",
            descriptor: "Mac Mini Old"
        )
        let newIdentity = TerminalWorkspaceBackendIdentity(
            teamID: "team_doc_new",
            taskID: "task_doc_new",
            taskRunID: "task_run_doc_new",
            workspaceName: "macmini-new",
            descriptor: "Mac Mini New"
        )
        let workspace = TerminalWorkspace(
            hostID: localHost.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-macmini",
            backendIdentity: oldIdentity,
            backendMetadata: TerminalWorkspaceBackendMetadata(preview: "feature/old")
        )
        let fixture = makeStore(
            snapshot: TerminalStoreSnapshot(
                hosts: [localHost],
                workspaces: [workspace],
                selectedWorkspaceID: nil
            ),
            workspaceIdentityService: StubTerminalWorkspaceIdentityService { host in
                switch host.teamID {
                case "team_doc_new":
                    return newIdentity
                default:
                    return oldIdentity
                }
            },
            workspaceMetadataService: StubTerminalWorkspaceMetadataService()
        )

        fixture.store.applyDiscoveredHosts([discoveredHost])

        try await waitForCondition {
            fixture.store.workspace(with: workspace.id)?.backendIdentity == newIdentity
        }

        fixture.metadataService?.send(
            TerminalWorkspaceBackendMetadata(preview: "feature/stale"),
            for: oldIdentity
        )
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(fixture.store.workspace(with: workspace.id)?.backendMetadata)

        let newMetadata = TerminalWorkspaceBackendMetadata(preview: "feature/new")
        fixture.metadataService?.send(newMetadata, for: newIdentity)

        try await waitForCondition {
            fixture.store.workspace(with: workspace.id)?.backendMetadata == newMetadata
        }

        XCTAssertEqual(fixture.store.workspace(with: workspace.id)?.backendIdentity, newIdentity)
        XCTAssertEqual(fixture.store.workspace(with: workspace.id)?.backendMetadata, newMetadata)
        XCTAssertEqual(fixture.snapshotStore.load().workspaces.first?.backendIdentity, newIdentity)
        XCTAssertEqual(fixture.snapshotStore.load().workspaces.first?.backendMetadata, newMetadata)
        XCTAssertEqual(fixture.identityService?.recordedHostIDs, [localHost.id])
    }

    @MainActor
    func testOpenWorkspaceMarksUnreadWorkspaceRead() throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint
        )
        let unreadWorkspace = TerminalWorkspace(
            hostID: host.id,
            title: "Nightly",
            tmuxSessionName: "cmux-nightly",
            preview: "tail -f nightly.log",
            unread: true
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [unreadWorkspace],
            selectedWorkspaceID: nil
        )
        let store = makeStore(snapshot: snapshot).store

        _ = store.openWorkspace(unreadWorkspace)

        let reopenedWorkspace = try XCTUnwrap(store.workspace(with: unreadWorkspace.id))
        XCTAssertEqual(store.selectedWorkspaceID, unreadWorkspace.id)
        XCTAssertFalse(reopenedWorkspace.unread)
    }

    @MainActor
    func testOpenWorkspaceDoesNotAttachUntilDetailIsVisible() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon,
            teamID: "team-1",
            serverID: "cmux-macmini"
        )
        let workspace = TerminalWorkspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            hostID: host.id,
            title: "Main",
            tmuxSessionName: "cmux-main"
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [workspace],
            selectedWorkspaceID: nil
        )

        let connectExpectation = expectation(description: "visible workspace connected")
        let disconnectExpectation = expectation(description: "hidden workspace disconnected")
        let transport = ConnectedStubTerminalTransport(
            onConnect: {
                connectExpectation.fulfill()
            },
            onDisconnect: {
                disconnectExpectation.fulfill()
            }
        )
        let fixture = makeStore(
            snapshot: snapshot,
            passwords: [host.id: "secret"],
            transportFactory: StubTerminalTransportFactory(transport: transport)
        )

        _ = fixture.store.openWorkspace(workspace)
        await Task.yield()

        XCTAssertEqual(fixture.store.selectedWorkspaceID, workspace.id)
        XCTAssertEqual(transport.connectCallCount, 0)

        fixture.store.setWorkspaceDetailVisible(workspace.id, visible: true)
        await fulfillment(of: [connectExpectation], timeout: 1.0)

        fixture.store.setWorkspaceDetailVisible(workspace.id, visible: false)
        await fulfillment(of: [disconnectExpectation], timeout: 1.0)

        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertEqual(transport.disconnectCallCount, 1)
    }

    @MainActor
    func testEagerSessionRestoreDoesNotAttachUntilDetailIsVisible() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon,
            teamID: "team-1",
            serverID: "cmux-macmini"
        )
        let workspace = TerminalWorkspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            hostID: host.id,
            title: "Main",
            tmuxSessionName: "cmux-main"
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [workspace],
            selectedWorkspaceID: workspace.id
        )

        let connectExpectation = expectation(description: "restored visible workspace connected")
        let disconnectExpectation = expectation(description: "restored hidden workspace disconnected")
        let transport = ConnectedStubTerminalTransport(
            onConnect: {
                connectExpectation.fulfill()
            },
            onDisconnect: {
                disconnectExpectation.fulfill()
            }
        )
        let fixture = makeStore(
            snapshot: snapshot,
            passwords: [host.id: "secret"],
            transportFactory: StubTerminalTransportFactory(transport: transport),
            eagerlyRestoreSessions: true
        )

        await Task.yield()

        XCTAssertEqual(fixture.store.selectedWorkspaceID, workspace.id)
        XCTAssertEqual(transport.connectCallCount, 0)

        fixture.store.setWorkspaceDetailVisible(workspace.id, visible: true)
        await fulfillment(of: [connectExpectation], timeout: 1.0)

        fixture.store.setWorkspaceDetailVisible(workspace.id, visible: false)
        await fulfillment(of: [disconnectExpectation], timeout: 1.0)

        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertEqual(transport.disconnectCallCount, 1)
    }

    @MainActor
    func testOpenInboxWorkspaceCreatesRemoteWorkspaceAndMarksRead() async throws {
        let readMarker = StubTerminalRemoteWorkspaceReadMarker()
        let fixture = makeStore(
            snapshot: TerminalStoreSnapshot(hosts: [], workspaces: [], selectedWorkspaceID: nil),
            remoteWorkspaceReadMarker: readMarker
        )
        let item = UnifiedInboxItem(
            kind: .workspace,
            workspaceID: "workspace_123",
            machineID: "machine_123",
            teamID: "team_123",
            title: "orb / cmux",
            preview: "feature/dogfood-inbox",
            unreadCount: 1,
            sortDate: Date(timeIntervalSince1970: 20),
            accessoryLabel: "Mac Mini",
            symbolName: "terminal",
            tmuxSessionName: "cmux-nightly",
            latestEventSeq: 4,
            lastReadEventSeq: 2,
            tailscaleHostname: "cmux-macmini.tail",
            tailscaleIPs: ["100.64.0.10"]
        )

        let workspaceID = try XCTUnwrap(fixture.store.openInboxWorkspace(item))

        try await waitForCondition {
            readMarker.items.count == 1
        }

        let host = try XCTUnwrap(fixture.store.hosts.first(where: { $0.stableID == "machine_123" }))
        let workspace = try XCTUnwrap(fixture.store.workspace(with: workspaceID))

        #if DEBUG && targetEnvironment(simulator)
        XCTAssertEqual(host.hostname, "127.0.0.1")
        #else
        XCTAssertEqual(host.hostname, "cmux-macmini.tail")
        #endif
        XCTAssertEqual(host.serverID, "cmux-macmini.tail")
        XCTAssertEqual(host.transportPreference, .remoteDaemon)
        XCTAssertEqual(workspace.remoteWorkspaceID, "workspace_123")
        XCTAssertEqual(workspace.tmuxSessionName, "cmux-nightly")
        XCTAssertEqual(fixture.store.selectedWorkspaceID, workspaceID)
        XCTAssertFalse(workspace.unread)
        XCTAssertEqual(readMarker.items.first?.workspaceID, "workspace_123")
    }

    @MainActor
    func testOpenInboxWorkspaceTracksWorkspaceOpenedAnalytics() {
        let analyticsTracker = StubTerminalAnalyticsTracker()
        let fixture = makeStore(
            snapshot: TerminalStoreSnapshot(hosts: [], workspaces: [], selectedWorkspaceID: nil),
            analyticsTracker: analyticsTracker
        )
        let item = UnifiedInboxItem(
            kind: .workspace,
            workspaceID: "workspace_123",
            machineID: "machine_123",
            teamID: "team_123",
            title: "orb / cmux",
            preview: "feature/dogfood-inbox",
            unreadCount: 2,
            sortDate: Date(timeIntervalSince1970: 20),
            accessoryLabel: "Mac Mini",
            symbolName: "terminal",
            tmuxSessionName: "cmux-nightly",
            latestEventSeq: 4,
            lastReadEventSeq: 2,
            tailscaleHostname: "cmux-macmini.tail",
            tailscaleIPs: ["100.64.0.10"]
        )

        _ = fixture.store.openInboxWorkspace(item)

        XCTAssertEqual(analyticsTracker.events.count, 1)
        XCTAssertEqual(analyticsTracker.events.first?.event, .mobileWorkspaceOpened)
        XCTAssertEqual(analyticsTracker.events.first?.properties.teamId, "team_123")
        XCTAssertEqual(analyticsTracker.events.first?.properties.machineId, "machine_123")
        XCTAssertEqual(analyticsTracker.events.first?.properties.workspaceId, "workspace_123")
        XCTAssertEqual(analyticsTracker.events.first?.properties.source, "inbox")
        XCTAssertEqual(analyticsTracker.events.first?.properties.unreadCount, 2)
    }

    @MainActor
    func testBellUpdatesSelectedWorkspaceActivityWithoutMarkingUnread() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .rawSSH
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Primary Terminal",
            tmuxSessionName: "cmux-primary",
            lastActivity: Date(timeIntervalSince1970: 10)
        )
        let surface = StubTerminalSurface()
        let fixture = makeStore(
            snapshot: TerminalStoreSnapshot(
                hosts: [host],
                workspaces: [workspace],
                selectedWorkspaceID: workspace.id
            ),
            passwords: [host.id: "secret"],
            controllerFactory: { workspace, host, credentialsStore, transportFactory in
                TerminalSessionController(
                    workspace: workspace,
                    host: host,
                    credentialsStore: credentialsStore,
                    transportFactory: transportFactory,
                    surfaceFactory: { _ in surface }
                )
            }
        )

        _ = fixture.store.openWorkspace(workspace)
        fixture.store.setWorkspaceDetailVisible(workspace.id, visible: true)

        NotificationCenter.default.post(
            name: .ghosttySurfaceDidRingBell,
            object: surface
        )

        try await waitForCondition {
            guard let updatedWorkspace = fixture.store.workspace(with: workspace.id) else { return false }
            return updatedWorkspace.lastActivity > workspace.lastActivity
        }

        let updatedWorkspace = try XCTUnwrap(fixture.store.workspace(with: workspace.id))
        XCTAssertEqual(fixture.store.selectedWorkspaceID, workspace.id)
        XCTAssertFalse(updatedWorkspace.unread)
    }

    @MainActor
    func testSaveHostPersistsPasswordAndHostMetadata() throws {
        let fixture = makeStore()
        let store = fixture.store
        let originalHost = try XCTUnwrap(store.hosts.first)
        var updatedHost = originalHost
        updatedHost.hostname = "orb"
        updatedHost.username = "lawrence"

        store.saveHost(
            updatedHost,
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil)
        )

        let persistedHost = try XCTUnwrap(fixture.snapshotStore.load().hosts.first(where: { $0.id == updatedHost.id }))
        XCTAssertEqual(persistedHost.hostname, "orb")
        XCTAssertEqual(fixture.credentialsStore.password(for: updatedHost.id), "secret")
    }

    @MainActor
    func testSaveHostNormalizesDirectTLSPins() throws {
        let fixture = makeStore()
        let store = fixture.store
        let originalHost = try XCTUnwrap(store.hosts.first)
        var updatedHost = originalHost
        updatedHost.transportPreference = .remoteDaemon
        updatedHost.allowsSSHFallback = false
        updatedHost.directTLSPins = [" sha256:pin-a ", "", "sha256:pin-a", "sha256:pin-b "]

        store.saveHost(
            updatedHost,
            credentials: TerminalSSHCredentials(password: nil, privateKey: nil)
        )

        let persistedHost = try XCTUnwrap(
            fixture.snapshotStore.load().hosts.first(where: { $0.id == updatedHost.id })
        )
        XCTAssertEqual(persistedHost.transportPreference, .remoteDaemon)
        XCTAssertFalse(persistedHost.allowsSSHFallback)
        XCTAssertEqual(persistedHost.directTLSPins, ["sha256:pin-a", "sha256:pin-b"])
    }

    @MainActor
    func testApplyDiscoveredHostsPreservesPersistedWorkspaceHostIDs() throws {
        let existingHost = TerminalHost(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            stableID: "cmux-macmini",
            name: "Old Label",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .rawSSH
        )
        let existingWorkspace = TerminalWorkspace(
            hostID: existingHost.id,
            title: "Mac mini",
            tmuxSessionName: "cmux-macmini"
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [existingHost],
            workspaces: [existingWorkspace],
            selectedWorkspaceID: existingWorkspace.id
        )
        let fixture = makeStore(snapshot: snapshot)

        fixture.store.applyDiscoveredHosts([
            TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac Mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon
            )
        ])

        XCTAssertEqual(fixture.store.workspaces.first?.hostID, existingHost.id)
        XCTAssertEqual(fixture.store.hosts.first?.id, existingHost.id)
        XCTAssertEqual(fixture.store.hosts.first?.name, "Mac Mini")
        XCTAssertEqual(fixture.store.hosts.first?.transportPreference, .remoteDaemon)
    }

    @MainActor
    func testApplyRemoteWorkspacesPersistsPrunedSnapshot() throws {
        let host = TerminalHost(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
            stableID: "127.0.0.1-52126",
            name: "Local Dev (:52126)",
            hostname: "127.0.0.1",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon
        )
        let liveWorkspace = TerminalWorkspace(
            hostID: host.id,
            title: "Live",
            tmuxSessionName: "sess-live",
            remoteWorkspaceID: "remote-live"
        )
        let staleWorkspace = TerminalWorkspace(
            hostID: host.id,
            title: "Stale",
            tmuxSessionName: "sess-stale",
            remoteWorkspaceID: "remote-stale"
        )
        let fixture = makeStore(
            snapshot: TerminalStoreSnapshot(
                hosts: [host],
                workspaces: [staleWorkspace, liveWorkspace],
                selectedWorkspaceID: staleWorkspace.id
            )
        )

        fixture.store.applyRemoteWorkspaces(
            [
                [
                    "id": "remote-live",
                    "title": "Live",
                    "session_id": "sess-live",
                    "last_activity_at": Int64(1_800_000_000_000),
                ],
            ],
            hostID: host.id,
            host: host
        )

        XCTAssertEqual(fixture.store.workspaces.map(\.remoteWorkspaceID), ["remote-live"])
        XCTAssertEqual(fixture.store.selectedWorkspaceID, liveWorkspace.id)
        XCTAssertEqual(fixture.snapshotStore.load().workspaces.map(\.remoteWorkspaceID), ["remote-live"])
        XCTAssertEqual(fixture.snapshotStore.load().selectedWorkspaceID, liveWorkspace.id)
    }

    @MainActor
    func testApplyRemoteWorkspacesUsesDaemonUUIDAsLocalWorkspaceID() throws {
        let host = TerminalHost(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
            stableID: "127.0.0.1-52190",
            name: "Local Dev (:52190)",
            hostname: "127.0.0.1",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon
        )
        let remoteID = "11111111-1111-1111-1111-111111111111"
        let oldLocalID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let existing = TerminalWorkspace(
            id: oldLocalID,
            hostID: host.id,
            title: "Local ID",
            tmuxSessionName: "sess-old",
            remoteWorkspaceID: remoteID
        )
        let fixture = makeStore(
            snapshot: TerminalStoreSnapshot(
                hosts: [host],
                workspaces: [existing],
                selectedWorkspaceID: oldLocalID
            )
        )

        fixture.store.applyRemoteWorkspaces(
            [
                [
                    "id": remoteID,
                    "title": "Remote ID",
                    "session_id": "sess-remote",
                    "last_activity_at": Int64(1_800_000_000_000),
                ],
            ],
            hostID: host.id,
            host: host
        )

        let daemonUUID = try XCTUnwrap(UUID(uuidString: remoteID))
        let workspace = try XCTUnwrap(fixture.store.workspaces.first)
        XCTAssertEqual(workspace.id, daemonUUID)
        XCTAssertEqual(workspace.remoteWorkspaceID, remoteID)
        XCTAssertEqual(fixture.store.selectedWorkspaceID, daemonUUID)
        XCTAssertEqual(fixture.snapshotStore.load().workspaces.first?.id, daemonUUID)
        XCTAssertEqual(fixture.snapshotStore.load().selectedWorkspaceID, daemonUUID)
    }

    @MainActor
    func testDiscoveredWorkspaceRevisionFetchesAuthoritativeSnapshotOnce() async throws {
        let discovery = StubTerminalServerDiscovery()
        let fetcher = StubWorkspaceListFetcher(results: [
            TerminalRemoteDaemonWorkspaceListResult(
                workspaces: [
                    Self.remoteWorkspaceEntry(
                        id: "11111111-1111-1111-1111-111111111111",
                        title: "Desktop A",
                        sessionID: "session-a"
                    ),
                ],
                selectedWorkspaceID: nil,
                changeSeq: 7
            ),
            TerminalRemoteDaemonWorkspaceListResult(
                workspaces: [
                    Self.remoteWorkspaceEntry(
                        id: "22222222-2222-2222-2222-222222222222",
                        title: "Desktop B",
                        sessionID: "session-b"
                    ),
                ],
                selectedWorkspaceID: nil,
                changeSeq: 8
            ),
        ])
        let fixture = makeStore(
            snapshot: TerminalStoreSnapshot(hosts: [], workspaces: [], selectedWorkspaceID: nil),
            serverDiscovery: discovery,
            workspaceListFetcher: { host in
                try await fetcher.fetch(host: host)
            },
            workspaceSubscriptionStarter: { _, _ in false }
        )
        let host = TerminalHost(
            stableID: "cmuxd-dev-test",
            name: "Local Dev (:52195)",
            hostname: "127.0.0.1",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .sky,
            source: .discovered,
            transportPreference: .remoteDaemon,
            serverID: "cmuxd-dev-test",
            wsPort: 52195,
            wsSecret: "secret",
            machineStatus: .online,
            daemonWorkspaceChangeSeq: 7
        )

        discovery.send([host])
        try await waitForCondition {
            fixture.store.workspaces.map(\.title) == ["Desktop A"]
        }
        var callCount = await fetcher.recordedCallCount()
        XCTAssertEqual(callCount, 1)

        discovery.send([host])
        await Task.yield()
        callCount = await fetcher.recordedCallCount()
        XCTAssertEqual(callCount, 1)

        var updatedHost = host
        updatedHost.daemonWorkspaceChangeSeq = 8
        discovery.send([updatedHost])
        try await waitForCondition {
            fixture.store.workspaces.map(\.title) == ["Desktop B"]
        }
        callCount = await fetcher.recordedCallCount()
        XCTAssertEqual(callCount, 2)
    }

    @MainActor
    func testDaemonSubscriptionConnectedRestoresPersistedRemoteWorkspaceStatus() async throws {
        let discovery = StubTerminalServerDiscovery()
        let host = TerminalHost(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000034")!,
            stableID: "127.0.0.1-52191",
            name: "Local Dev (:52191)",
            hostname: "127.0.0.1",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon,
            serverID: "127.0.0.1-52191",
            wsPort: 52191,
            wsSecret: "secret",
            machineStatus: .offline
        )
        let liveWorkspace = TerminalWorkspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000035")!,
            hostID: host.id,
            title: "Live",
            tmuxSessionName: "sess-live",
            phase: .disconnected,
            lastError: "Offline",
            remoteWorkspaceID: "remote-live"
        )
        let pendingWorkspace = TerminalWorkspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000036")!,
            hostID: host.id,
            title: "Pending",
            tmuxSessionName: "pending-remote",
            phase: .disconnected,
            lastError: "Offline",
            remoteWorkspaceID: "remote-pending"
        )
        let fixture = makeStore(
            snapshot: TerminalStoreSnapshot(
                hosts: [host],
                workspaces: [pendingWorkspace, liveWorkspace],
                selectedWorkspaceID: liveWorkspace.id
            ),
            serverDiscovery: discovery,
            workspaceSubscriptionStarter: { _, onEvent in
                onEvent(.connected)
                return true
            }
        )

        var onlineHost = host
        onlineHost.machineStatus = .online
        discovery.send([onlineHost])

        try await waitForCondition {
            fixture.store.workspace(with: liveWorkspace.id)?.phase == .connected
        }

        XCTAssertEqual(fixture.store.server(for: host.id)?.machineStatus, .online)
        XCTAssertEqual(fixture.store.workspace(with: liveWorkspace.id)?.phase, .connected)
        XCTAssertNil(fixture.store.workspace(with: liveWorkspace.id)?.lastError)
        XCTAssertEqual(fixture.store.workspace(with: pendingWorkspace.id)?.phase, .disconnected)
        let persistedWorkspace = fixture.snapshotStore.load().workspaces.first { $0.id == liveWorkspace.id }
        XCTAssertEqual(persistedWorkspace?.phase, .connected)
        XCTAssertNil(persistedWorkspace?.lastError)
    }

    @MainActor
    func testApplyDiscoveredHostsReplacesPlaceholderCustomHostWithLiveMachine() throws {
        let placeholderHost = TerminalHost(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            stableID: "cmux-setup",
            name: "Mac Mini",
            hostname: "",
            username: "",
            symbolName: "desktopcomputer",
            palette: .mint,
            sortIndex: 0,
            source: .custom,
            transportPreference: .rawSSH
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [placeholderHost],
            workspaces: [],
            selectedWorkspaceID: nil
        )
        let fixture = makeStore(snapshot: snapshot)

        fixture.store.applyDiscoveredHosts([
            TerminalHost(
                stableID: "machine-macmini-live",
                name: "Mac Mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini",
                allowsSSHFallback: false
            )
        ])

        let host = try XCTUnwrap(fixture.store.hosts.first)
        XCTAssertEqual(fixture.store.hosts.count, 1)
        XCTAssertEqual(host.id, placeholderHost.id)
        XCTAssertEqual(host.stableID, "machine-macmini-live")
        XCTAssertEqual(host.source, .discovered)
        XCTAssertEqual(host.serverID, "cmux-macmini")
        XCTAssertTrue(fixture.store.isConfigured(host))
    }

    @MainActor
    func testIsConfiguredAllowsDirectDaemonHostWithoutPassword() {
        let host = TerminalHost(
            stableID: "cmux-macmini",
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: "team-1",
            serverID: "cmux-macmini"
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [],
            selectedWorkspaceID: nil
        )
        let store = makeStore(snapshot: snapshot).store

        XCTAssertTrue(store.isConfigured(host))
    }

    func testDirectDaemonHostsDoNotRequireSavedSSHPassword() {
        let host = TerminalHost(
            stableID: "cmux-macmini",
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: "team-1",
            serverID: "cmux-macmini"
        )
        XCTAssertFalse(host.requiresSavedSSHPassword)
    }

    func testManualDirectDaemonHostsWithoutTeamScopeRequireSSHPassword() {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .custom,
            transportPreference: .remoteDaemon,
            sshAuthenticationMethod: .password
        )

        XCTAssertTrue(host.requiresSavedSSHPassword)
    }

    func testRawSSHHostsStillRequireSavedSSHPassword() {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .rawSSH,
            sshAuthenticationMethod: .password
        )
        XCTAssertTrue(host.requiresSavedSSHPassword)
    }

    @MainActor
    func testIsConfiguredStillRequiresPasswordForRawSSHHost() {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .rawSSH,
            sshAuthenticationMethod: .password
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [],
            selectedWorkspaceID: nil
        )
        let store = makeStore(snapshot: snapshot).store

        XCTAssertFalse(store.isConfigured(host))
    }

    @MainActor
    func testIsConfiguredRequiresCredentialForManualDirectDaemonHostWithoutTeamScope() {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .custom,
            transportPreference: .remoteDaemon,
            sshAuthenticationMethod: .password
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [],
            selectedWorkspaceID: nil
        )
        let store = makeStore(snapshot: snapshot).store

        XCTAssertFalse(store.isConfigured(host))
    }

    @MainActor
    func testIsConfiguredAllowsPrivateKeyForRawSSHHost() {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .rawSSH,
            sshAuthenticationMethod: .privateKey
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [],
            selectedWorkspaceID: nil
        )
        let fixture = makeStore(snapshot: snapshot)

        XCTAssertFalse(fixture.store.isConfigured(host))

        fixture.store.saveHost(
            host,
            credentials: TerminalSSHCredentials(
                password: nil,
                privateKey: TerminalSSHPrivateKeyFixtures.opensshEd25519PrivateKey
            )
        )

        XCTAssertTrue(fixture.store.isConfigured(host))
        XCTAssertEqual(
            fixture.credentialsStore.privateKey(for: host.id),
            TerminalSSHPrivateKeyFixtures.opensshEd25519PrivateKey
        )
    }

    @MainActor
    func testIsConfiguredAllowsPrivateKeyForManualDirectDaemonHostWithoutTeamScope() {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .custom,
            transportPreference: .remoteDaemon,
            sshAuthenticationMethod: .privateKey
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [],
            selectedWorkspaceID: nil
        )
        let fixture = makeStore(snapshot: snapshot)

        XCTAssertFalse(fixture.store.isConfigured(host))

        fixture.store.saveHost(
            host,
            credentials: TerminalSSHCredentials(
                password: nil,
                privateKey: TerminalSSHPrivateKeyFixtures.opensshEd25519PrivateKey
            )
        )

        XCTAssertTrue(fixture.store.isConfigured(host))
    }

    @MainActor
    func testDeleteHostRemovesItsWorkspacesAndSelection() throws {
        let fixture = makeStore()
        let store = fixture.store
        let host = try XCTUnwrap(store.hosts.first)

        store.saveHost(
            host,
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil)
        )
        let workspaceID = store.startWorkspace(on: host)
        let workspace = try XCTUnwrap(store.workspace(with: workspaceID))

        store.deleteHost(host)

        XCTAssertTrue(store.hosts.isEmpty)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNil(store.selectedWorkspaceID)
        XCTAssertNil(fixture.credentialsStore.password(for: host.id))
        XCTAssertNil(fixture.snapshotStore.load().workspaces.first(where: { $0.id == workspace.id }))
    }

    func testPreviewExtractorStripsControlSequences() throws {
        let data = Data("\u{001B}[32mready\u{001B}[0m\r\ncmux@host:~$ ".utf8)

        let preview = try XCTUnwrap(TerminalPreviewExtractor.preview(from: data))

        XCTAssertEqual(preview, "cmux@host:~$")
    }

    func testSnapshotStoreRoundTripsHostsWorkspacesAndSelection() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_710_000_000)
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini",
            lastActivity: fixedDate,
            remoteDaemonResumeState: .init(
                sessionID: "sess-1",
                attachmentID: "att-1",
                readOffset: 42
            )
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [workspace],
            selectedWorkspaceID: workspace.id
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let store = TerminalSnapshotStore(fileURL: fileURL)
        try store.save(snapshot)

        let reloaded = store.load()

        XCTAssertEqual(reloaded, snapshot)
        try FileManager.default.removeItem(at: fileURL)
    }

    @MainActor
    func testControllerCreationPersistsInitialSurfaceFailure() async throws {
        let surfaceError = "Ghostty surface boot failed."
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .rawSSH
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [workspace],
            selectedWorkspaceID: workspace.id
        )
        let surfaceFactory = FailThenSucceedSurfaceFactory()
        let fixture = makeStore(
            snapshot: snapshot,
            passwords: [host.id: "secret"],
            controllerFactory: { workspace, host, credentialsStore, _ in
                TerminalSessionController(
                    workspace: workspace,
                    host: host,
                    credentialsStore: credentialsStore,
                    transportFactory: StubTerminalTransportFactory(transport: ConnectedStubTerminalTransport()),
                    surfaceFactory: surfaceFactory.makeSurface(delegate:)
                )
            }
        )

        let controller = fixture.store.controller(for: workspace)
        controller.connectIfNeeded()
        try await waitForCondition {
            surfaceFactory.attemptCount == 1 && controller.phase == .failed
        }

        let persistedWorkspace = try XCTUnwrap(
            fixture.snapshotStore.load().workspaces.first(where: { $0.id == workspace.id })
        )

        XCTAssertEqual(surfaceFactory.attemptCount, 1)
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(controller.errorMessage, surfaceError)
        XCTAssertEqual(persistedWorkspace.phase, .failed)
        XCTAssertEqual(persistedWorkspace.lastError, surfaceError)
    }

    @MainActor
    func testOpenWorkspacePersistsPendingHostKeyForUnknownSSHHostKey() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .rawSSH
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [workspace],
            selectedWorkspaceID: nil
        )
        let fixture = makeStore(
            snapshot: snapshot,
            passwords: [host.id: "secret"],
            controllerFactory: { workspace, host, credentialsStore, _ in
                TerminalSessionController(
                    workspace: workspace,
                    host: host,
                    credentialsStore: credentialsStore,
                    transportFactory: StubTerminalTransportFactory(
                        transport: ThrowingStubTerminalTransport(
                            connectError: TerminalSSHError.untrustedHostKey("ssh-ed25519 AAAAPENDING")
                        )
                    ),
                    surfaceFactory: { _ in StubTerminalSurface() }
                )
            }
        )

        _ = fixture.store.openWorkspace(workspace)
        fixture.store.setWorkspaceDetailVisible(workspace.id, visible: true)

        try await waitForCondition {
            fixture.store.server(for: host.id)?.pendingHostKey == "ssh-ed25519 AAAAPENDING" &&
                fixture.store.workspace(with: workspace.id)?.phase == .needsConfiguration
        }

        let persistedHost = try XCTUnwrap(
            fixture.snapshotStore.load().hosts.first(where: { $0.id == host.id })
        )
        let persistedWorkspace = try XCTUnwrap(
            fixture.snapshotStore.load().workspaces.first(where: { $0.id == workspace.id })
        )

        XCTAssertEqual(persistedHost.pendingHostKey, "ssh-ed25519 AAAAPENDING")
        XCTAssertEqual(persistedWorkspace.phase, .needsConfiguration)
        XCTAssertEqual(
            persistedWorkspace.lastError,
            "Review and trust this server host key before connecting."
        )
    }

    @MainActor
    func testOpenWorkspacePersistsPendingHostKeyForChangedSSHHostKey() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            trustedHostKey: "ssh-ed25519 AAAAOLD",
            transportPreference: .rawSSH
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [workspace],
            selectedWorkspaceID: nil
        )
        let fixture = makeStore(
            snapshot: snapshot,
            passwords: [host.id: "secret"],
            controllerFactory: { workspace, host, credentialsStore, _ in
                TerminalSessionController(
                    workspace: workspace,
                    host: host,
                    credentialsStore: credentialsStore,
                    transportFactory: StubTerminalTransportFactory(
                        transport: ThrowingStubTerminalTransport(
                            connectError: TerminalSSHError.hostKeyChanged("ssh-ed25519 AAAANEW")
                        )
                    ),
                    surfaceFactory: { _ in StubTerminalSurface() }
                )
            }
        )

        _ = fixture.store.openWorkspace(workspace)
        fixture.store.setWorkspaceDetailVisible(workspace.id, visible: true)

        try await waitForCondition {
            fixture.store.server(for: host.id)?.pendingHostKey == "ssh-ed25519 AAAANEW" &&
                fixture.store.workspace(with: workspace.id)?.phase == .needsConfiguration
        }

        let persistedHost = try XCTUnwrap(
            fixture.snapshotStore.load().hosts.first(where: { $0.id == host.id })
        )
        let persistedWorkspace = try XCTUnwrap(
            fixture.snapshotStore.load().workspaces.first(where: { $0.id == workspace.id })
        )

        XCTAssertEqual(persistedHost.pendingHostKey, "ssh-ed25519 AAAANEW")
        XCTAssertEqual(persistedHost.trustedHostKey, "ssh-ed25519 AAAAOLD")
        XCTAssertEqual(persistedWorkspace.phase, .needsConfiguration)
        XCTAssertEqual(
            persistedWorkspace.lastError,
            "The server host key changed. Review and trust the new key before connecting."
        )
    }

    @MainActor
    func testWorkspaceDetailVisibilitySuspendsInactiveControllerAndConnectsVisibleWorkspace() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon,
            teamID: "team-1",
            serverID: "cmux-macmini"
        )
        let firstWorkspace = TerminalWorkspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            hostID: host.id,
            title: "First",
            tmuxSessionName: "cmux-first"
        )
        let secondWorkspace = TerminalWorkspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            hostID: host.id,
            title: "Second",
            tmuxSessionName: "cmux-second"
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [firstWorkspace, secondWorkspace],
            selectedWorkspaceID: nil
        )

        let firstConnectExpectation = expectation(description: "first workspace connected")
        let firstDisconnectExpectation = expectation(description: "first workspace disconnected")
        let secondConnectExpectation = expectation(description: "second workspace connected")
        let firstWorkspaceTransports = [
            ConnectedStubTerminalTransport(
                onConnect: {
                    firstConnectExpectation.fulfill()
                },
                onDisconnect: {
                    firstDisconnectExpectation.fulfill()
                }
            ),
            ConnectedStubTerminalTransport(),
        ]
        let secondWorkspaceTransports = [
            ConnectedStubTerminalTransport(
                onConnect: {
                    secondConnectExpectation.fulfill()
                }
            ),
        ]
        let firstTransportFactory = TrackingSequencedTerminalTransportFactory(
            transports: firstWorkspaceTransports
        )
        let secondTransportFactory = TrackingSequencedTerminalTransportFactory(
            transports: secondWorkspaceTransports
        )
        let firstSurfaceFactory = SequencedStubTerminalSurfaceFactory(
            surfaces: [
                StubTerminalSurface(),
                StubTerminalSurface(
                    gridSize: TerminalGridSize(columns: 96, rows: 30, pixelWidth: 960, pixelHeight: 600)
                ),
            ]
        )
        let secondSurfaceFactory = SequencedStubTerminalSurfaceFactory(
            surfaces: [StubTerminalSurface()]
        )

        let fixture = makeStore(
            snapshot: snapshot,
            passwords: [host.id: "secret"],
            eagerlyRestoreSessions: false,
            controllerFactory: { workspace, host, credentialsStore, _ in
                let surfaceFactory = workspace.id == firstWorkspace.id
                    ? firstSurfaceFactory.makeSurface(delegate:)
                    : secondSurfaceFactory.makeSurface(delegate:)
                let transportFactory: TerminalTransportFactory = workspace.id == firstWorkspace.id
                    ? firstTransportFactory
                    : secondTransportFactory
                return TerminalSessionController(
                    workspace: workspace,
                    host: host,
                    credentialsStore: credentialsStore,
                    transportFactory: transportFactory,
                    surfaceFactory: surfaceFactory
                )
            }
        )

        _ = fixture.store.controller(for: firstWorkspace)
        _ = fixture.store.controller(for: secondWorkspace)
        _ = fixture.store.openWorkspace(firstWorkspace)
        fixture.store.setWorkspaceDetailVisible(firstWorkspace.id, visible: true)
        await fulfillment(of: [firstConnectExpectation], timeout: 1.0)
        XCTAssertEqual(firstWorkspaceTransports[0].connectCallCount, 1)
        XCTAssertEqual(secondWorkspaceTransports[0].connectCallCount, 0)

        _ = fixture.store.openWorkspace(secondWorkspace)
        fixture.store.setWorkspaceDetailVisible(firstWorkspace.id, visible: false)
        fixture.store.setWorkspaceDetailVisible(secondWorkspace.id, visible: true)
        await fulfillment(of: [firstDisconnectExpectation, secondConnectExpectation], timeout: 1.0)

        XCTAssertEqual(firstWorkspaceTransports[0].disconnectCallCount, 1)
        XCTAssertEqual(secondWorkspaceTransports[0].connectCallCount, 1)
    }

    @MainActor
    func testNetworkLossSuspendsVisibleWorkspaceAndRestorationResumesIt() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon,
            teamID: "team-1",
            serverID: "cmux-macmini"
        )
        let workspace = TerminalWorkspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            hostID: host.id,
            title: "Main",
            tmuxSessionName: "cmux-main"
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [workspace],
            selectedWorkspaceID: nil
        )

        let firstConnectExpectation = expectation(description: "first transport connected")
        let firstDisconnectExpectation = expectation(description: "first transport disconnected")
        let secondConnectExpectation = expectation(description: "second transport connected")
        let transports = [
            ConnectedStubTerminalTransport(
                onConnect: {
                    firstConnectExpectation.fulfill()
                },
                onDisconnect: {
                    firstDisconnectExpectation.fulfill()
                }
            ),
            ConnectedStubTerminalTransport(
                onConnect: {
                    secondConnectExpectation.fulfill()
                }
            ),
        ]
        let transportFactory = TrackingSequencedTerminalTransportFactory(transports: transports)
        let networkMonitor = StubTerminalNetworkPathMonitor(
            currentState: TerminalNetworkPathState(isReachable: true, signature: "wifi")
        )
        let fixture = makeStore(
            snapshot: snapshot,
            passwords: [host.id: "secret"],
            transportFactory: transportFactory,
            networkPathMonitor: networkMonitor
        )
        fixture.store.simulateNetworkPathUpdateForTesting(
            TerminalNetworkPathState(isReachable: true, signature: "wifi")
        )

        _ = fixture.store.openWorkspace(workspace)
        fixture.store.setWorkspaceDetailVisible(workspace.id, visible: true)
        await fulfillment(of: [firstConnectExpectation], timeout: 1.0)

        networkMonitor.send(TerminalNetworkPathState(isReachable: false, signature: "offline"))
        await fulfillment(of: [firstDisconnectExpectation], timeout: 1.0)

        networkMonitor.send(TerminalNetworkPathState(isReachable: true, signature: "cellular"))
        await fulfillment(of: [secondConnectExpectation], timeout: 1.0)

        XCTAssertEqual(transports[0].disconnectCallCount, 1)
        XCTAssertEqual(transports[1].connectCallCount, 1)
    }

    @MainActor
    func testReachablePathChangeReconnectsVisibleConnectedWorkspace() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon,
            teamID: "team-1",
            serverID: "cmux-macmini"
        )
        let workspace = TerminalWorkspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
            hostID: host.id,
            title: "Main",
            tmuxSessionName: "cmux-main"
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [workspace],
            selectedWorkspaceID: nil
        )

        let firstConnectExpectation = expectation(description: "first transport connected")
        let firstDisconnectExpectation = expectation(description: "first transport disconnected")
        let secondConnectExpectation = expectation(description: "second transport connected after path change")
        let transports = [
            ConnectedStubTerminalTransport(
                onConnect: {
                    firstConnectExpectation.fulfill()
                },
                onDisconnect: {
                    firstDisconnectExpectation.fulfill()
                }
            ),
            ConnectedStubTerminalTransport(
                onConnect: {
                    secondConnectExpectation.fulfill()
                }
            ),
        ]
        let transportFactory = TrackingSequencedTerminalTransportFactory(transports: transports)
        let networkMonitor = StubTerminalNetworkPathMonitor(
            currentState: TerminalNetworkPathState(isReachable: true, signature: "wifi")
        )
        let fixture = makeStore(
            snapshot: snapshot,
            passwords: [host.id: "secret"],
            transportFactory: transportFactory,
            networkPathMonitor: networkMonitor
        )

        _ = fixture.store.openWorkspace(workspace)
        fixture.store.setWorkspaceDetailVisible(workspace.id, visible: true)
        await fulfillment(of: [firstConnectExpectation], timeout: 1.0)

        networkMonitor.send(TerminalNetworkPathState(isReachable: true, signature: "cellular"))
        await fulfillment(of: [firstDisconnectExpectation, secondConnectExpectation], timeout: 1.0)

        XCTAssertEqual(transports[0].disconnectCallCount, 1)
        XCTAssertEqual(transports[1].connectCallCount, 1)
    }

    @MainActor
    func testApplyRemoteWorkspacesReconnectsVisibleWorkspaceWhenDaemonSessionIDChanges() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon,
            teamID: "team-1",
            serverID: "cmux-macmini"
        )
        let workspace = TerminalWorkspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000024")!,
            hostID: host.id,
            title: "Main",
            tmuxSessionName: "sess-stale",
            remoteWorkspaceID: "remote-1"
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [workspace],
            selectedWorkspaceID: nil
        )

        let firstConnectExpectation = expectation(description: "initial transport connected")
        let firstDisconnectExpectation = expectation(description: "stale transport disconnected")
        let replacementConnectExpectation = expectation(description: "replacement transport connected")
        let transports = [
            ConnectedStubTerminalTransport(
                onConnect: {
                    firstConnectExpectation.fulfill()
                },
                onDisconnect: {
                    firstDisconnectExpectation.fulfill()
                }
            ),
            ConnectedStubTerminalTransport(
                onConnect: {
                    replacementConnectExpectation.fulfill()
                }
            ),
        ]
        let transportFactory = TrackingSequencedTerminalTransportFactory(transports: transports)
        let fixture = makeStore(
            snapshot: snapshot,
            passwords: [host.id: "secret"],
            transportFactory: transportFactory
        )

        _ = fixture.store.openWorkspace(workspace)
        fixture.store.setWorkspaceDetailVisible(workspace.id, visible: true)
        await fulfillment(of: [firstConnectExpectation], timeout: 1.0)

        fixture.store.applyRemoteWorkspaces(
            [[
                "id": "remote-1",
                "title": "Main",
                "preview": "",
                "unread_count": 0,
                "last_activity_at": Int64(Date().timeIntervalSince1970 * 1000),
                "session_id": "sess-fresh",
                "pinned": false,
                "panes": [],
            ]],
            hostID: host.id,
            host: host
        )

        await fulfillment(of: [firstDisconnectExpectation, replacementConnectExpectation], timeout: 1.0)

        XCTAssertEqual(transports[0].disconnectCallCount, 1)
        XCTAssertEqual(transports[1].connectCallCount, 1)
        XCTAssertEqual(fixture.store.workspaces.first?.tmuxSessionName, "sess-fresh")
    }

    @MainActor
    func testReachablePathChangeReconnectsVisibleConnectingWorkspace() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon,
            teamID: "team-1",
            serverID: "cmux-macmini"
        )
        let workspace = TerminalWorkspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000023")!,
            hostID: host.id,
            title: "Main",
            tmuxSessionName: "cmux-main"
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [workspace],
            selectedWorkspaceID: nil
        )

        let connectGate = AsyncGate()
        let initialConnectStartedExpectation = expectation(description: "initial connect started")
        let initialDisconnectExpectation = expectation(description: "initial transport disconnected after path change")
        let replacementConnectedExpectation = expectation(description: "replacement transport connected after path change")
        let initialTransport = BlockingConnectStubTerminalTransport(
            gate: connectGate,
            onConnectStarted: {
                initialConnectStartedExpectation.fulfill()
            },
            onDisconnect: {
                initialDisconnectExpectation.fulfill()
            }
        )
        let replacementTransport = ConnectedStubTerminalTransport(
            onConnect: {
                replacementConnectedExpectation.fulfill()
            }
        )
        let transportFactory = TrackingSequencedTerminalTransportFactory(
            transports: [initialTransport, replacementTransport]
        )
        let networkMonitor = StubTerminalNetworkPathMonitor(
            currentState: TerminalNetworkPathState(isReachable: true, signature: "wifi")
        )
        let fixture = makeStore(
            snapshot: snapshot,
            passwords: [host.id: "secret"],
            transportFactory: transportFactory,
            networkPathMonitor: networkMonitor
        )

        _ = fixture.store.openWorkspace(workspace)
        fixture.store.setWorkspaceDetailVisible(workspace.id, visible: true)
        await fulfillment(of: [initialConnectStartedExpectation], timeout: 1.0)
        let visibleController = fixture.store.controller(for: workspace)
        XCTAssertEqual(visibleController.phase, .reconnecting)

        fixture.store.simulateNetworkPathUpdateForTesting(
            TerminalNetworkPathState(isReachable: true, signature: "cellular")
        )
        await fulfillment(of: [initialDisconnectExpectation, replacementConnectedExpectation], timeout: 1.0)

        XCTAssertEqual(initialTransport.disconnectCallCount, 1)
        XCTAssertEqual(replacementTransport.connectCallCount, 1)

        await connectGate.open()
        await Task.yield()

        XCTAssertEqual(replacementTransport.connectCallCount, 1)
    }

    @MainActor
    private func makeStore(
        snapshot: TerminalStoreSnapshot = .seed(),
        passwords: [TerminalHost.ID: String] = [:],
        transportFactory: TerminalTransportFactory = DefaultTerminalTransportFactory(),
        workspaceIdentityService: StubTerminalWorkspaceIdentityService? = nil,
        workspaceMetadataService: StubTerminalWorkspaceMetadataService? = nil,
        remoteWorkspaceReadMarker: TerminalRemoteWorkspaceReadMarking? = nil,
        analyticsTracker: MobileAnalyticsTracking? = nil,
        serverDiscovery: TerminalServerDiscovering? = nil,
        networkPathMonitor: TerminalNetworkPathMonitoring? = nil,
        eagerlyRestoreSessions: Bool = false,
        controllerFactory: TerminalSessionControllerFactory? = nil,
        workspaceListFetcher: TerminalWorkspaceListFetcher? = nil,
        workspaceSubscriptionStarter: TerminalWorkspaceSubscriptionStarter? = nil
    ) -> (
        store: TerminalSidebarStore,
        snapshotStore: InMemoryTerminalSnapshotStore,
        credentialsStore: InMemoryTerminalCredentialsStore,
        identityService: StubTerminalWorkspaceIdentityService?,
        metadataService: StubTerminalWorkspaceMetadataService?
    ) {
        let snapshotStore = InMemoryTerminalSnapshotStore(snapshot: snapshot)
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: passwords)
        let resolvedControllerFactory = controllerFactory ?? { workspace, host, credentialsStore, transportFactory in
            TerminalSessionController(
                workspace: workspace,
                host: host,
                credentialsStore: credentialsStore,
                transportFactory: transportFactory,
                surfaceFactory: { _ in StubTerminalSurface() }
            )
        }
        let store = TerminalSidebarStore(
            snapshotStore: snapshotStore,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            workspaceIdentityService: workspaceIdentityService,
            workspaceMetadataService: workspaceMetadataService,
            serverDiscovery: serverDiscovery,
            networkPathMonitor: networkPathMonitor,
            remoteWorkspaceReadMarker: remoteWorkspaceReadMarker,
            analyticsTracker: analyticsTracker,
            eagerlyRestoreSessions: eagerlyRestoreSessions,
            controllerFactory: resolvedControllerFactory,
            workspaceListFetcher: workspaceListFetcher,
            workspaceSubscriptionStarter: workspaceSubscriptionStarter
        )
        return (store, snapshotStore, credentialsStore, workspaceIdentityService, workspaceMetadataService)
    }

    private static func remoteWorkspaceEntry(
        id: String,
        title: String,
        sessionID: String
    ) -> TerminalRemoteDaemonWorkspaceEntry {
        TerminalRemoteDaemonWorkspaceEntry(
            id: id,
            title: title,
            directory: "/",
            focusedPaneID: "pane-\(id)",
            paneCount: 1,
            createdAt: 1_800_000_000_000,
            lastActivityAt: 1_800_000_000_000,
            sessionID: sessionID,
            preview: nil,
            unreadCount: nil,
            pinned: nil,
            panes: [
                TerminalRemoteDaemonWorkspacePane(
                    id: "pane-\(id)",
                    sessionID: sessionID,
                    title: title,
                    directory: "/"
                ),
            ]
        )
    }

}

@MainActor
private func waitForCondition(
    timeout: Duration = .seconds(1),
    pollInterval: Duration = .milliseconds(10),
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() {
            return
        }
        try await Task.sleep(for: pollInterval)
    }
    XCTFail("Timed out waiting for condition.")
}

private final class StubTerminalNetworkPathMonitor: TerminalNetworkPathMonitoring {
    private let subject = PassthroughSubject<TerminalNetworkPathState, Never>()
    private(set) var currentState: TerminalNetworkPathState?

    init(currentState: TerminalNetworkPathState? = nil) {
        self.currentState = currentState
    }

    var statePublisher: AnyPublisher<TerminalNetworkPathState, Never> {
        subject.eraseToAnyPublisher()
    }

    func send(_ state: TerminalNetworkPathState) {
        currentState = state
        subject.send(state)
    }
}

private final class StubTerminalServerDiscovery: TerminalServerDiscovering {
    private let subject = PassthroughSubject<[TerminalHost], Never>()

    var hostsPublisher: AnyPublisher<[TerminalHost], Never> {
        subject.eraseToAnyPublisher()
    }

    func send(_ hosts: [TerminalHost]) {
        subject.send(hosts)
    }
}

private actor StubWorkspaceListFetcher {
    private var results: [TerminalRemoteDaemonWorkspaceListResult]
    private var callCount = 0

    init(results: [TerminalRemoteDaemonWorkspaceListResult]) {
        self.results = results
    }

    func fetch(host: TerminalHost) throws -> TerminalRemoteDaemonWorkspaceListResult {
        callCount += 1
        guard !results.isEmpty else {
            throw StubWorkspaceListFetcherError.missingResult(host.stableID)
        }
        return results.removeFirst()
    }

    func recordedCallCount() -> Int {
        callCount
    }
}

private enum StubWorkspaceListFetcherError: Error {
    case missingResult(String)
}

@MainActor
private final class StubTerminalWorkspaceIdentityService: TerminalWorkspaceIdentityReserving {
    private let reserveHandler: @MainActor (TerminalHost) -> TerminalWorkspaceBackendIdentity
    private(set) var recordedHostIDs: [TerminalHost.ID] = []

    init(identity: TerminalWorkspaceBackendIdentity) {
        self.reserveHandler = { _ in identity }
    }

    init(reserveHandler: @escaping @MainActor (TerminalHost) -> TerminalWorkspaceBackendIdentity) {
        self.reserveHandler = reserveHandler
    }

    func reserveWorkspace(for host: TerminalHost) async throws -> TerminalWorkspaceBackendIdentity {
        recordedHostIDs.append(host.id)
        return reserveHandler(host)
    }
}

@MainActor
private final class StubTerminalWorkspaceMetadataService: TerminalWorkspaceMetadataStreaming {
    private var subjects: [String: PassthroughSubject<TerminalWorkspaceBackendMetadata, Never>] = [:]

    func metadataPublisher(for identity: TerminalWorkspaceBackendIdentity) -> AnyPublisher<TerminalWorkspaceBackendMetadata, Never> {
        let key = key(for: identity)
        if let subject = subjects[key] {
            return subject.eraseToAnyPublisher()
        }
        let subject = PassthroughSubject<TerminalWorkspaceBackendMetadata, Never>()
        subjects[key] = subject
        return subject.eraseToAnyPublisher()
    }

    func send(_ metadata: TerminalWorkspaceBackendMetadata, for identity: TerminalWorkspaceBackendIdentity) {
        subjects[key(for: identity)]?.send(metadata)
    }

    private func key(for identity: TerminalWorkspaceBackendIdentity) -> String {
        "\(identity.teamID):\(identity.taskRunID)"
    }
}

@MainActor
private final class StubTerminalRemoteWorkspaceReadMarker: TerminalRemoteWorkspaceReadMarking {
    private(set) var items: [UnifiedInboxItem] = []

    func markRead(item: UnifiedInboxItem) async throws {
        items.append(item)
    }
}

@MainActor
private final class StubTerminalAnalyticsTracker: MobileAnalyticsTracking {
    private(set) var events: [(event: MobileAnalyticsEventName, properties: MobileAnalyticsProperties)] = []

    func capture(event: MobileAnalyticsEventName, properties: MobileAnalyticsProperties) {
        events.append((event, properties))
    }
}
