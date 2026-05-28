import XCTest
import UserNotifications
@testable import CmuxKit
@testable import CmuxRemote

final class NotificationPayloadTests: XCTestCase {
    @MainActor
    func testAgentDecisionUserInfoOmitsNilOptionalIdentifiers() throws {
        let decision = AgentDecision(
            id: "decision-1",
            itemID: "B7CC0A6A-3A3C-47A9-85D5-076355686432",
            workspaceID: nil,
            surfaceID: nil,
            agentName: "codex",
            kind: .diff,
            summary: "Diff approval",
            detail: nil,
            choices: [
                .init(id: "apply", label: "Apply", style: .affirmative, requiresAuth: true),
                .init(id: "reject", label: "Reject", style: .destructive, requiresAuth: false)
            ],
            expiresAt: nil
        )

        let userInfo = AgentDecisionNotifier.userInfo(for: decision)

        XCTAssertNil(userInfo["workspace_id"])
        XCTAssertNil(userInfo["surface_id"])
        XCTAssertEqual(userInfo["item_id"] as? String, "B7CC0A6A-3A3C-47A9-85D5-076355686432")
        XCTAssertNotEqual(userInfo["agent_name"] as? String, "codex")
        XCTAssertNoThrow(
            try PropertyListSerialization.data(
                fromPropertyList: userInfo,
                format: .binary,
                options: 0
            )
        )
    }

    @MainActor
    func testAgentDecisionUserInfoIncludesHostIDWhenPresent() throws {
        let hostID = UUID(uuidString: "7804514A-276C-47C4-92A4-316D49B86849")!
        let decision = AgentDecision(
            id: "decision-host-scoped",
            hostID: hostID,
            itemID: "A2F7DF10-4386-468D-B8B2-DC9BDEAA7AD2",
            workspaceID: nil,
            surfaceID: nil,
            agentName: "codex",
            kind: .diff,
            summary: "Diff approval",
            detail: nil,
            choices: [
                .init(id: "apply", label: "Apply", style: .affirmative, requiresAuth: true),
                .init(id: "reject", label: "Reject", style: .destructive, requiresAuth: false)
            ],
            expiresAt: nil
        )

        let userInfo = AgentDecisionNotifier.userInfo(for: decision)

        XCTAssertEqual(userInfo["host_id"] as? String, hostID.uuidString)
        XCTAssertEqual(userInfo["item_id"] as? String, "A2F7DF10-4386-468D-B8B2-DC9BDEAA7AD2")
        XCTAssertNoThrow(
            try PropertyListSerialization.data(
                fromPropertyList: userInfo,
                format: .binary,
                options: 0
            )
        )
    }

    @MainActor
    func testAgentDecisionNotificationIdentifierIsHostScoped() {
        let hostID = UUID(uuidString: "7804514A-276C-47C4-92A4-316D49B86849")!
        let decision = AgentDecision(
            id: "same-request-id",
            hostID: hostID,
            itemID: "A2F7DF10-4386-468D-B8B2-DC9BDEAA7AD2",
            workspaceID: nil,
            surfaceID: nil,
            agentName: "codex",
            kind: .diff,
            summary: "Diff approval",
            detail: nil,
            choices: [
                .init(id: "apply", label: "Apply", style: .affirmative, requiresAuth: true),
                .init(id: "reject", label: "Reject", style: .destructive, requiresAuth: false)
            ],
            expiresAt: nil
        )

        let request = AgentDecisionNotifier.makeRequest(for: decision)

        XCTAssertEqual(request.identifier, "decision:\(hostID.uuidString):same-request-id")
    }

    @MainActor
    func testAgentDecisionNotificationTitleRedactsAgentSource() {
        let decision = AgentDecision(
            id: "decision-source-redaction",
            itemID: "DC5571CB-B1A4-4524-BE41-58731236762E",
            workspaceID: nil,
            surfaceID: nil,
            agentName: "secret-client-production-agent",
            kind: .diff,
            summary: "Diff approval",
            detail: nil,
            choices: [
                .init(id: "apply", label: "Apply", style: .affirmative, requiresAuth: true),
                .init(id: "reject", label: "Reject", style: .destructive, requiresAuth: false)
            ],
            expiresAt: nil
        )

        let request = AgentDecisionNotifier.makeRequest(for: decision)

        XCTAssertFalse(request.content.title.contains("secret-client"))
        XCTAssertFalse(
            (AgentDecisionNotifier.userInfo(for: decision)["agent_name"] as? String)?
                .contains("secret-client") ?? true
        )
    }

    @MainActor
    func testPrivilegedAgentDecisionNotificationActionsRequireAuthentication() {
        let decision = AgentDecision(
            id: "decision-2",
            itemID: "E44E4E3A-7756-4A53-BDA3-56A2CB90D014",
            workspaceID: nil,
            surfaceID: nil,
            agentName: "codex",
            kind: .toolCall,
            summary: "Run command",
            detail: nil,
            choices: [
                .init(id: "allow", label: "Allow once", style: .affirmative, requiresAuth: false),
                .init(id: "allow_session", label: "Allow this session", style: .default, requiresAuth: false),
                .init(id: "deny", label: "Deny", style: .destructive, requiresAuth: false)
            ],
            expiresAt: nil
        )

        let category = AgentDecisionNotifier.makeCategory(for: decision)
        let actions = Dictionary(uniqueKeysWithValues: category.actions.map { ($0.identifier, $0) })

        XCTAssertTrue(actions["A"]?.options.contains(.authenticationRequired) ?? false)
        XCTAssertTrue(actions["B"]?.options.contains(.authenticationRequired) ?? false)
        XCTAssertTrue(actions["C"]?.options.contains(.authenticationRequired) ?? false)
    }

    @MainActor
    func testUnboundAgentDecisionNotificationCategoryHasNoActions() {
        let decision = AgentDecision(
            id: "decision-unbound",
            workspaceID: nil,
            surfaceID: nil,
            agentName: "codex",
            kind: .toolCall,
            summary: "Run command",
            detail: nil,
            choices: [
                .init(id: "allow", label: "Allow once", style: .affirmative, requiresAuth: true),
                .init(id: "deny", label: "Deny", style: .destructive, requiresAuth: false)
            ],
            expiresAt: nil
        )

        let category = AgentDecisionNotifier.makeCategory(for: decision)

        XCTAssertTrue(category.actions.isEmpty)
    }

    func testStuckSurfaceUserInfoOmitsNilWorkspaceID() {
        let userInfo = RemoteNotificationUserInfo.stuckSurface(
            surfaceID: SurfaceID("surface-1"),
            workspaceID: nil
        )

        XCTAssertEqual(userInfo["surface_id"] as? String, "surface-1")
        XCTAssertNil(userInfo["workspace_id"])
        XCTAssertNoThrow(
            try PropertyListSerialization.data(
                fromPropertyList: userInfo,
                format: .binary,
                options: 0
            )
        )
    }

    func testStuckSurfaceUserInfoIncludesHostIDWhenPresent() {
        let hostID = UUID(uuidString: "6211C5B3-1391-4B2D-8E45-BE8953B794E3")!
        let userInfo = RemoteNotificationUserInfo.stuckSurface(
            surfaceID: SurfaceID("surface-1"),
            workspaceID: WorkspaceID("workspace-1"),
            hostID: hostID
        )

        XCTAssertEqual(userInfo["host_id"] as? String, hostID.uuidString)
        XCTAssertEqual(userInfo["workspace_id"] as? String, "workspace-1")
        XCTAssertEqual(userInfo["surface_id"] as? String, "surface-1")
        XCTAssertNoThrow(
            try PropertyListSerialization.data(
                fromPropertyList: userInfo,
                format: .binary,
                options: 0
            )
        )
    }

    func testCmuxNotificationPresentationRedactsServerContentByDefault() {
        let notification = CmuxNotification(
            id: NotificationID("notification-1"),
            workspaceID: nil,
            surfaceID: nil,
            title: "Codex needs approval",
            subtitle: "cmux workspace",
            body: "Review the pending diff before it is applied.",
            tabTitle: "feature/remote",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isRead: false
        )

        XCTAssertEqual(CmuxNotificationPresentation.title(for: notification), "cmux notification")
        XCTAssertEqual(CmuxNotificationPresentation.subtitle(for: notification), "")
        XCTAssertEqual(
            CmuxNotificationPresentation.body(for: notification),
            "An agent needs attention. Open cmux-remote to view details."
        )
    }

    func testCmuxNotificationPresentationIgnoresFallbackContentForLockScreenPrivacy() {
        let notification = CmuxNotification(
            id: NotificationID("notification-2"),
            workspaceID: nil,
            surfaceID: nil,
            title: " ",
            subtitle: "",
            body: nil,
            tabTitle: "remote tab",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isRead: false
        )

        XCTAssertEqual(CmuxNotificationPresentation.title(for: notification), "cmux notification")
        XCTAssertEqual(CmuxNotificationPresentation.subtitle(for: notification), "")
        XCTAssertEqual(
            CmuxNotificationPresentation.body(for: notification),
            "An agent needs attention. Open cmux-remote to view details."
        )
    }
}
