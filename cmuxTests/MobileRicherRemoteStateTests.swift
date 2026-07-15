import AppKit
import Bonsplit
import CMUXMobileCore
import CmuxCore
import CmuxSidebar
import Foundation
@preconcurrency import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct MobileRicherRemoteStateTests {
    @Test func hostAdvertisesRicherRemoteStateCapabilities() {
        let capabilities = MobileHostService.mobileHostCapabilities
        #expect(capabilities.contains("workspace.remote_state.v1"))
        #expect(capabilities.contains("view.presence.v1"))
    }

    @Test func richerRemoteStateProjectsExistingWorkspaceStoresAndChangesObserverHash() throws {
        let (workspace, panelIDs) = try makeWorkspaceWithSplitTerminals(count: 2)
        let firstPanelID = try #require(panelIDs.first)
        let secondPanelID = try #require(panelIDs.last)
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        defer { store.replaceNotificationsForTesting(previousNotifications) }
        store.replaceNotificationsForTesting([])

        let initialHash = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        workspace.setAgentLifecycle(key: "codex", panelId: firstPanelID, lifecycle: .running)
        workspace.setAgentLifecycle(key: "codex", panelId: secondPanelID, lifecycle: .needsInput)
        workspace.setAgentLifecycle(key: "claude_code", panelId: firstPanelID, lifecycle: .idle)
        workspace.updatePanelGitBranch(panelId: firstPanelID, branch: "feat/richer-state", isDirty: true)
        workspace.updatePanelPullRequest(
            panelId: firstPanelID,
            number: 8082,
            label: "PR",
            url: try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/8082")),
            status: .open,
            branch: "feat/richer-state"
        )

        let notificationID = UUID()
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: notificationID,
                tabId: workspace.id,
                surfaceId: nil,
                title: "Needs attention",
                subtitle: "",
                body: "Review the agent request",
                createdAt: Date(),
                isRead: false
            )
        ])

        let payload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: nil,
            notificationStore: store
        )
        let remoteState = try #require(payload["remote_state"] as? [String: Any])
        #expect(remoteState["version"] as? Int == 1)

        let agents = try #require(remoteState["agents"] as? [[String: Any]])
        #expect(agents.map { $0["agent"] as? String } == ["claude_code", "codex"])
        let codex = try #require(agents.first { $0["agent"] as? String == "codex" })
        #expect(codex["state"] as? String == "needs_input")
        #expect((codex["panel_ids"] as? [String])?.count == 2)

        let git = try #require(remoteState["git"] as? [String: Any])
        #expect(git["branch"] as? String == "feat/richer-state")
        #expect(git["is_dirty"] as? Bool == true)

        let pullRequest = try #require(remoteState["pull_request"] as? [String: Any])
        #expect(pullRequest["number"] as? Int == 8082)
        #expect(pullRequest["state"] as? String == "open")
        #expect(pullRequest["ci_status"] as? String == "unknown")

        let notifications = try #require(remoteState["notifications"] as? [String: Any])
        #expect(notifications["unread_count"] as? Int == 1)
        #expect(notifications["has_unread"] as? Bool == true)
        #expect(notifications["latest_notification_id"] as? String == notificationID.uuidString)

        let changedHash = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(initialHash != changedHash)
    }

    @Test func viewPresenceGroupsStableClientIDsAcrossConnections() throws {
        let service = MobileHostService.shared
        let firstConnectionID = UUID()
        let secondConnectionID = UUID()
        let thirdConnectionID = UUID()
        service.debugResetMobileLifecycleStateForTesting()
        defer { service.debugResetMobileLifecycleStateForTesting() }

        service.recordClientID("phone-1", for: firstConnectionID)
        service.recordClientID("phone-1", for: firstConnectionID)
        service.recordClientID("phone-1", for: secondConnectionID)
        service.recordClientID("spoofed-client", for: secondConnectionID)
        service.recordClientID("mac-2", for: thirdConnectionID)

        let payload = service.viewPresencePayload()
        #expect(payload["version"] as? Int == 1)
        let views = try #require(payload["views"] as? [[String: Any]])
        #expect(views.map { $0["client_id"] as? String } == ["mac-2", "phone-1"])
        #expect(views.first { $0["client_id"] as? String == "phone-1" }?["connection_count"] as? Int == 2)
        #expect(views.first { $0["client_id"] as? String == "mac-2" }?["connection_count"] as? Int == 1)

        service.debugRemoveConnectionForTesting(id: secondConnectionID)
        let remaining = try #require(service.viewPresencePayload()["views"] as? [[String: Any]])
        #expect(remaining.count == 2)
        #expect(remaining.first { $0["client_id"] as? String == "phone-1" }?["connection_count"] as? Int == 1)
    }

    @Test func unauthenticatedStatusAndInvalidIDsDoNotRegisterPresence() {
        let service = MobileHostService.shared
        let connectionID = UUID()
        service.debugResetMobileLifecycleStateForTesting()
        defer { service.debugResetMobileLifecycleStateForTesting() }

        service.recordViewPresence(
            for: MobileHostRPCRequest(
                id: "status",
                method: "mobile.host.status",
                params: ["client_id": "spoofed-client"],
                auth: nil
            ),
            connectionID: connectionID,
            authorization: .stackBearer
        )
        service.recordViewPresence(
            for: MobileHostRPCRequest(
                id: "list",
                method: "workspace.list",
                params: ["client_id": String(repeating: "x", count: 129)],
                auth: nil
            ),
            connectionID: connectionID,
            authorization: .stackBearer
        )

        let views = service.viewPresencePayload()["views"] as? [[String: Any]]
        #expect(views?.isEmpty == true)
    }

    @Test func freshEventSubscriptionRunsCatchupAfterInstallation() async throws {
        let requestRecorder = MobileHostConnectionRequestRecorder()
        let authorizedRequestRecorded = AsyncTestSignal()
        let socket = try MobileHostStartedTestSocket()
        defer { socket.close() }
        let session = MobileHostConnection(
            id: UUID(),
            connection: socket.connection,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { request in
                await requestRecorder.record(request)
                authorizedRequestRecorded.fulfill()
            },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        let frame = try MobileSyncFrameCodec.encodeFrame(
            Data(#"{"id":"subscribe","method":"mobile.events.subscribe","params":{"stream_id":"events","topics":["workspace.updated"]}}"#.utf8)
        )

        await session.debugHandleReceiveDataForTesting(frame)
        try await authorizedRequestRecorded.wait()

        #expect(await session.isSubscribed(to: "workspace.updated"))
        #expect(await requestRecorder.recordedMethods() == ["mobile.events.subscribe"])
    }

    private func makeWorkspaceWithSplitTerminals(count: Int) throws -> (Workspace, [UUID]) {
        precondition(count >= 1)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        var orderedIDs = [try #require(workspace.focusedPanelId)]
        for _ in 1..<count {
            let previous = try #require(orderedIDs.last)
            let panel = try #require(
                workspace.newTerminalSplit(from: previous, orientation: .horizontal, focus: false)
            )
            orderedIDs.append(panel.id)
        }
        return (workspace, orderedIDs)
    }
}
