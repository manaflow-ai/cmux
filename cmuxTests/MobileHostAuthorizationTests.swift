import CMUXMobileCore
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MobileHostAuthorizationTests: XCTestCase {
    func testAttachTicketStoreKeepsMultipleTicketsForSameTerminal() throws {
        let store = MobileAttachTicketStore()
        let route = try CmxAttachRoute(
            id: "debug",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58465)
        )
        let now = Date()

        let first = try store.createTicket(
            workspaceID: "workspace",
            terminalID: "terminal",
            routes: [route],
            ttl: 3600,
            now: now
        )
        let second = try store.createTicket(
            workspaceID: "workspace",
            terminalID: "terminal",
            routes: [route],
            ttl: 3600,
            now: now.addingTimeInterval(1)
        )

        XCTAssertNotEqual(first.authToken, second.authToken)
        XCTAssertEqual(
            store.validTicket(authToken: first.authToken, now: now.addingTimeInterval(2))?.authToken,
            first.authToken
        )
        XCTAssertEqual(
            store.validTicket(authToken: second.authToken, now: now.addingTimeInterval(2))?.authToken,
            second.authToken
        )
    }

    func testMobileWorkspaceRPCRequiresAuthorization() async {
        let request = MobileHostRPCRequest(
            id: "workspace-list",
            method: "workspace.list",
            params: [:],
            auth: nil
        )

        let result = await MobileHostService.shared.debugAuthorizationError(for: request)

        guard case let .failure(error) = result else {
            return XCTFail("workspace.list should require mobile authorization")
        }
        XCTAssertEqual(error.code, "unauthorized")
    }

    func testMobileHostStatusDoesNotRequireAuthorization() async {
        let request = MobileHostRPCRequest(
            id: "host-status",
            method: "mobile.host.status",
            params: [:],
            auth: nil
        )

        let result = await MobileHostService.shared.debugAuthorizationError(for: request)

        XCTAssertNil(result)
    }

    func testMobileRouteResolverPrefersTailscaleMagicDNSBeforeIPv4Fallback() throws {
        let resolver = MobileRouteResolver()

        let snapshot = resolver.routes(
            port: 61234,
            tailscaleHosts: [
                "work-mac.tailnet.ts.net",
                "100.71.210.41",
            ]
        )

        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        XCTAssertEqual(tailscaleRoutes.count, 2)
        XCTAssertEqual(tailscaleRoutes.first?.priority, 10)
        XCTAssertEqual(tailscaleRoutes.last?.priority, 20)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            XCTAssertEqual(host, "work-mac.tailnet.ts.net")
            XCTAssertEqual(port, 61234)
        } else {
            XCTFail("Expected first Tailscale route to use a host/port endpoint")
        }
        if case let .hostPort(host, port) = tailscaleRoutes.last?.endpoint {
            XCTAssertEqual(host, "100.71.210.41")
            XCTAssertEqual(port, 61234)
        } else {
            XCTFail("Expected fallback Tailscale route to use a host/port endpoint")
        }
    }

    func testMobileAttachTicketCreateRequiresAuthorization() async {
        let request = MobileHostRPCRequest(
            id: "attach-ticket-create",
            method: "mobile.attach_ticket.create",
            params: [:],
            auth: nil
        )

        let result = await MobileHostService.shared.debugAuthorizationError(for: request)

        guard case let .failure(error) = result else {
            return XCTFail("mobile.attach_ticket.create should require mobile authorization")
        }
        XCTAssertEqual(error.code, "unauthorized")
    }

    func testScopedAttachTicketRejectsWorkspaceAliasIgnoredByHandlers() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: nil)
        let request = MobileHostRPCRequest(
            id: "workspace-list",
            method: "workspace.list",
            params: ["workspaceID": "workspace"],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil,
                stackRefreshToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        XCTAssertEqual(error?.code, "forbidden")
    }

    func testScopedAttachTicketRejectsTerminalAliasIgnoredByHandlers() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal")
        let request = MobileHostRPCRequest(
            id: "terminal-input",
            method: "terminal.input",
            params: [
                "workspace_id": "workspace",
                "terminalID": "terminal",
            ],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil,
                stackRefreshToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        XCTAssertEqual(error?.code, "forbidden")
    }

    func testScopedAttachTicketAcceptsHandlerParameterNames() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal")
        let request = MobileHostRPCRequest(
            id: "terminal-input",
            method: "terminal.input",
            params: [
                "workspace_id": "workspace",
                "terminal_id": "terminal",
            ],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil,
                stackRefreshToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        XCTAssertNil(error)
    }

    func testStackUserAuthorizationRequiresSignedInMacUser() throws {
        XCTAssertThrowsError(
            try MobileHostAuthorizationPolicy.authorizeStackUser(
                localUserID: nil,
                remoteUserID: "user_remote"
            )
        )
    }

    func testStackUserAuthorizationRequiresMatchingUser() throws {
        XCTAssertThrowsError(
            try MobileHostAuthorizationPolicy.authorizeStackUser(
                localUserID: "user_local",
                remoteUserID: "user_remote"
            )
        )

        XCTAssertNoThrow(
            try MobileHostAuthorizationPolicy.authorizeStackUser(
                localUserID: "user_local",
                remoteUserID: "user_local"
            )
        )
    }

    private func scopedAttachTicket(workspaceID: String, terminalID: String?) throws -> CmxAttachTicket {
        let route = try CmxAttachRoute(
            id: "debug",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58465)
        )
        return try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3600),
            authToken: "ticket-secret"
        )
    }
}
