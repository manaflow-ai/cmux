import CMUXMobileCore
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct MobileHostAttachTicketScopeTests {
    @Test func testScopedAttachTicketAcceptsTerminalMouse() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal")
        let request = MobileHostRPCRequest(
            id: "terminal-mouse",
            method: "mobile.terminal.mouse",
            params: [
                "workspace_id": "workspace",
                "surface_id": "terminal",
                "client_id": "ios-client",
                "col": 4,
                "row": 8,
            ],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        #expect(error == nil)
    }

    @Test func testScopedAttachTicketRejectsWorkspaceGroupMutation() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal")
        let request = MobileHostRPCRequest(
            id: "workspace-group-collapse",
            method: "workspace.group.collapse",
            params: ["group_id": "group-main"],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        #expect(error?.code == "forbidden")
    }

    @Test func testWorkspaceScopedAttachTicketAcceptsScopedWorkspaceList() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: nil)
        let request = MobileHostRPCRequest(
            id: "workspace-list",
            method: "workspace.list",
            params: ["workspace_id": "workspace"],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        #expect(error == nil)
    }

    @Test func testMacScopedAttachTicketAcceptsUnscopedFullWorkspaceList() throws {
        let ticket = try scopedAttachTicket(workspaceID: "", terminalID: nil)
        let request = MobileHostRPCRequest(
            id: "workspace-list",
            method: "workspace.list",
            params: [:],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        #expect(error == nil)
    }

    @Test(arguments: ["mobile.events.subscribe", "mobile.events.unsubscribe"])
    func testMacScopedAttachTicketAcceptsEventSubscription(method: String) throws {
        let ticket = try scopedAttachTicket(workspaceID: "", terminalID: nil)
        let request = MobileHostRPCRequest(
            id: "events",
            method: method,
            params: eventSubscriptionParams(method: method),
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        #expect(error == nil)
    }

    @Test(arguments: ["mobile.events.subscribe", "mobile.events.unsubscribe"])
    func testWorkspaceScopedAttachTicketRejectsEventSubscription(method: String) throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: nil)
        let request = MobileHostRPCRequest(
            id: "events",
            method: method,
            params: eventSubscriptionParams(method: method),
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        #expect(error?.code == "forbidden")
    }

    private func eventSubscriptionParams(method: String) -> [String: Any] {
        method == "mobile.events.subscribe"
            ? ["stream_id": "events", "topics": ["terminal.render_grid"]]
            : ["stream_id": "events"]
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
