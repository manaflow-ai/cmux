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
struct MobileHostWorkspaceTicketAuthorizationTests {
    @Test func testWorkspaceScopedTicketAuthorizesWorkspaceActionsOnlyForTicketWorkspace() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace")
        let cases: [(method: String, params: [String: String], expectedCode: String?)] = [
            ("workspace.action", ["workspace_id": "workspace", "action": "rename"], nil),
            ("workspace.action", ["workspace_id": "other-workspace", "action": "rename"], "forbidden"),
            ("workspace.close", ["workspace_id": "workspace"], nil),
            ("workspace.close", ["workspace_id": "other-workspace"], "forbidden"),
        ]

        for testCase in cases {
            let request = MobileHostRPCRequest(
                id: testCase.method,
                method: testCase.method,
                params: testCase.params,
                auth: MobileHostRPCAuth(attachToken: ticket.authToken, stackAccessToken: nil)
            )
            let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
            #expect(error?.code == testCase.expectedCode)
        }
    }

    private func scopedAttachTicket(workspaceID: String) throws -> CmxAttachTicket {
        let route = try CmxAttachRoute(
            id: "debug",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58465)
        )
        return try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3600),
            authToken: "ticket-secret"
        )
    }
}
