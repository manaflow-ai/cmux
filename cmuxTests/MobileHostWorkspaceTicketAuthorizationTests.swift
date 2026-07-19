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
    private func loopbackRoute() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58465),
            priority: 0
        )
    }

    private func tailscaleRoute(
        id: String = "tailscale",
        host: String = "100.64.0.5",
        priority: Int = 10
    ) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: 58465),
            priority: priority
        )
    }

    private func compactTicket(from attachURL: String) throws -> CmxAttachTicket {
        let components = try #require(URLComponents(string: attachURL))
        var encoded = try #require(
            components.queryItems?.first(where: { $0.name == "payload" })?.value
        )
        encoded = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        let data = try #require(Data(base64Encoded: encoded))
        return try CmxAttachTicketCompactCoder().decode(data)
    }

    @Test func attachTargetsSelectOnlyRoutesValidForTheirDestination() throws {
        let loopback = try loopbackRoute()
        let tailscale = try tailscaleRoute()
        let routes = [loopback, tailscale]

        #expect(try MobileAttachTarget.simulatorInjection.selectRoutes(from: routes) == [loopback])
        #expect(try MobileAttachTarget.physicalDevice.selectRoutes(from: routes) == [tailscale])
        #expect(try MobileAttachTarget.ticketOnly.selectRoutes(from: routes) == routes)
    }

    @Test func emptyHostRoutesPreserveNoRoutesBeforeTargetFiltering() {
        #expect(throws: MobileAttachTicketStoreError.noRoutes) {
            try MobileAttachTarget.physicalDevice.selectRoutes(from: [])
        }
    }

    @Test func simulatorInjectionPayloadIsLosslessV1WithLoopbackToken() throws {
        let store = MobileAttachTicketStore()
        let ticket = try store.createTicket(
            workspaceID: "",
            terminalID: nil,
            routes: [try loopbackRoute()],
            ttl: 3600
        )

        let payload = try store.payload(for: ticket, target: .simulatorInjection)
        let attachURL = try #require(payload["attach_url"] as? String)
        #expect(attachURL.contains("?v=1&payload="))
        let decoded = try compactTicket(from: attachURL)
        #expect(decoded.routes == ticket.routes)
        #expect(decoded.authToken == ticket.authToken)
    }

    @Test func physicalDevicePayloadIsV2WithExactTailscaleRoutes() throws {
        let store = MobileAttachTicketStore()
        let ticket = try store.createTicket(
            workspaceID: "",
            terminalID: nil,
            routes: [try tailscaleRoute()],
            ttl: 3600
        )

        let payload = try store.payload(for: ticket, target: .physicalDevice)
        let attachURL = try #require(payload["attach_url"] as? String)
        let components = try #require(URLComponents(string: attachURL))
        #expect(components.queryItems?.first(where: { $0.name == "v" })?.value == "2")
        #expect(components.queryItems?.contains(where: { $0.name == "payload" }) == false)
        #expect(try CmxPairingQRCode().decode(components).routes == ticket.routes)
    }

    @Test func physicalDeviceCanonicalizesFilteredSecondaryRouteForV2() throws {
        let secondaryRoute = try tailscaleRoute(
            id: "tailscale_2",
            host: "100.64.0.6",
            priority: 20
        )
        let selectedRoutes = try MobileAttachTarget.physicalDevice.selectRoutes(from: [secondaryRoute])
        let selectedRoute = try #require(selectedRoutes.first)
        #expect(selectedRoute.id == "tailscale")
        #expect(selectedRoute.endpoint == secondaryRoute.endpoint)
        #expect(selectedRoute.priority == 10)

        let store = MobileAttachTicketStore()
        let ticket = try store.createTicket(
            workspaceID: "",
            terminalID: nil,
            routes: selectedRoutes,
            ttl: 3600
        )
        let payload = try store.payload(for: ticket, target: .physicalDevice)
        let attachURL = try #require(payload["attach_url"] as? String)
        let components = try #require(URLComponents(string: attachURL))
        #expect(try CmxPairingQRCode().decode(components).routes == ticket.routes)
    }

    @Test func ticketOnlyPayloadPreservesMixedRoutesWithoutAttachURL() throws {
        let store = MobileAttachTicketStore()
        let routes = [try loopbackRoute(), try tailscaleRoute()]
        let ticket = try store.createTicket(
            workspaceID: "",
            terminalID: nil,
            routes: routes,
            ttl: 3600
        )

        let payload = try store.payload(for: ticket, target: .ticketOnly)
        #expect(payload["attach_url"] == nil)
        #expect((payload["routes"] as? [[String: Any]])?.count == routes.count)
    }

    @Test func omittedTargetPreservesLegacyAttachURL() throws {
        let store = MobileAttachTicketStore()
        let ticket = try store.createTicket(
            workspaceID: "",
            terminalID: nil,
            routes: [try loopbackRoute()],
            ttl: 3600
        )

        let payload = try store.payload(for: ticket)
        let attachURL = try #require(payload["attach_url"] as? String)
        #expect(try compactTicket(from: attachURL).routes == ticket.routes)
    }

    #if DEBUG
    @Test func omittedTargetRPCPreservesLegacyAttachURL() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let service = MobileHostService.shared
        service.debugSetListenerStateForTesting(
            generation: UUID(),
            usesEphemeralFallback: false,
            port: 61_234
        )
        defer {
            service.debugSetListenerStateForTesting(
                generation: UUID(),
                usesEphemeralFallback: false,
                port: nil
            )
        }
        let workspace = try #require(manager.selectedWorkspace)

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "legacy-attach-ticket",
                method: "mobile.attach_ticket.create",
                params: ["workspace_id": workspace.id.uuidString],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any] else {
            return #expect(Bool(false), "Expected attach ticket payload")
        }
        #expect(payload["attach_url"] as? String != nil)
    }
    #endif

    @Test func physicalDevicePayloadNeverFallsBackToLoopbackV1() throws {
        let store = MobileAttachTicketStore()
        let ticket = try store.createTicket(
            workspaceID: "",
            terminalID: nil,
            routes: [try loopbackRoute()],
            ttl: 3600
        )

        #expect(throws: MobileAttachTicketStoreError.invalidAttachURL) {
            try store.payload(for: ticket, target: .physicalDevice)
        }
    }

    #if DEBUG
    @Test func attachTicketWithoutListenerPreservesNoRoutesError() async {
        let service = MobileHostService.shared
        service.debugSetListenerStateForTesting(
            generation: UUID(),
            usesEphemeralFallback: false,
            port: nil
        )

        await #expect(throws: MobileAttachTicketStoreError.noRoutes) {
            try await service.createAttachTicket(
                workspaceID: "workspace-main",
                terminalID: nil,
                ttl: 3600,
                target: .physicalDevice
            )
        }
    }
    #endif

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
