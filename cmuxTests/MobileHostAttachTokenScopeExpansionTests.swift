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
struct MobileHostAttachTokenScopeExpansionTests {
    @Test func testStackAuthorizedCreateDoesNotExpandOutOfScopeAttachToken() async throws {
        let service = MobileHostService.shared
        service.debugResetMobileLifecycleStateForTesting()
        service.debugConfigureAcceptedStackAuthTokenForTesting("cmux-dev-token")
        service.debugSetListenerStateForTesting(
            generation: UUID(),
            usesEphemeralFallback: true,
            port: CmxMobileDefaults.defaultHostPort
        )
        defer {
            service.debugConfigureAcceptedStackAuthTokenForTesting(nil)
            service.debugResetMobileLifecycleStateForTesting()
        }

        let payload = try await service.createAttachTicket(
            workspaceID: "workspace",
            terminalID: "terminal",
            ttl: 3600,
            routeKind: CmxAttachTransportKind.debugLoopback.rawValue
        )
        let ticketObject = try #require(payload["ticket"] as? [String: Any])
        let authToken = try #require(ticketObject["auth_token"] as? String)
        let createRequest = MobileHostRPCRequest(
            id: "workspace-create",
            method: "workspace.create",
            params: [:],
            auth: MobileHostRPCAuth(
                attachToken: authToken,
                stackAccessToken: "cmux-dev-token"
            )
        )

        #expect(await service.debugAuthorizationError(for: createRequest) == nil)
        service.debugRecordCreatedResourcesForTesting(
            request: createRequest,
            result: .ok(["created_workspace_id": "stack-created-workspace"])
        )

        let replayRequest = MobileHostRPCRequest(
            id: "terminal-replay",
            method: "terminal.replay",
            params: [
                "workspace_id": "stack-created-workspace",
                "surface_id": "created-terminal",
            ],
            auth: MobileHostRPCAuth(
                attachToken: authToken,
                stackAccessToken: nil
            )
        )

        let replayResult = await service.debugAuthorizationError(for: replayRequest)
        guard case let .failure(error) = replayResult else {
            return #expect(Bool(false), "Stack-authorized workspace.create must not expand the attach-token scope")
        }
        #expect(error.code == "forbidden")
    }
}
