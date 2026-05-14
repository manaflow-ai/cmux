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
        XCTAssertTrue(store.containsValidTicket(authToken: first.authToken, now: now.addingTimeInterval(2)))
        XCTAssertTrue(store.containsValidTicket(authToken: second.authToken, now: now.addingTimeInterval(2)))
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
}
