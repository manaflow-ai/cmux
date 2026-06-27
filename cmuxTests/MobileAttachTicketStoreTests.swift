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
struct MobileAttachTicketStoreTests {
    @Test func testValidationOnlyPrunesPresentedExpiredToken() throws {
        let store = MobileAttachTicketStore(maximumStoredTickets: 8)
        let route = try Self.debugRoute()
        let now = Date()
        let expired = try store.createTicket(
            workspaceID: "workspace",
            terminalID: "terminal",
            routes: [route],
            ttl: 30,
            now: now
        )
        let valid = try store.createTicket(
            workspaceID: "workspace",
            terminalID: "terminal",
            routes: [route],
            ttl: 30,
            now: now.addingTimeInterval(2)
        )
        let validationTime = now.addingTimeInterval(31)
        let beforeExpiredTicketExpiry = now.addingTimeInterval(29)

        #expect(store.validTicket(authToken: valid.authToken, now: validationTime)?.authToken == valid.authToken)
        #expect(
            store.validTicket(authToken: expired.authToken, now: beforeExpiredTicketExpiry)?.authToken == expired.authToken
        )

        #expect(store.validTicket(authToken: expired.authToken, now: validationTime) == nil)
        #expect(store.validTicket(authToken: valid.authToken, now: validationTime)?.authToken == valid.authToken)
    }

    @Test func testStoreCapsRetainedTickets() throws {
        let store = MobileAttachTicketStore(maximumStoredTickets: 2)
        let route = try Self.debugRoute()
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
        let third = try store.createTicket(
            workspaceID: "workspace",
            terminalID: "terminal",
            routes: [route],
            ttl: 3600,
            now: now.addingTimeInterval(2)
        )
        let validationTime = now.addingTimeInterval(3)

        #expect(store.validTicket(authToken: first.authToken, now: validationTime) == nil)
        #expect(store.validTicket(authToken: second.authToken, now: validationTime)?.authToken == second.authToken)
        #expect(store.validTicket(authToken: third.authToken, now: validationTime)?.authToken == third.authToken)
    }

    private static func debugRoute() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "debug",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58465)
        )
    }
}
