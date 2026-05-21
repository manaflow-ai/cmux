import CMUXMobileCore
@preconcurrency import Network
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

    #if DEBUG
    func testDebugStackAuthTokenPolicyRequiresConfiguredToken() {
        XCTAssertNil(MobileHostDevStackAuthPolicy.normalizedToken("   "))
        XCTAssertFalse(MobileHostDevStackAuthPolicy.authorize(
            providedToken: "cmux-dev-token",
            acceptedToken: nil
        ))
        XCTAssertFalse(MobileHostDevStackAuthPolicy.authorize(
            providedToken: "cmux-dev-token",
            acceptedToken: "other-token"
        ))
        XCTAssertTrue(MobileHostDevStackAuthPolicy.authorize(
            providedToken: " cmux-dev-token ",
            acceptedToken: "cmux-dev-token"
        ))
    }

    func testDebugConfiguredStackAuthTokenAuthorizesBroadWorkspaceList() async {
        let service = MobileHostService.shared
        service.debugConfigureAcceptedStackAuthTokenForTesting("cmux-dev-token")
        defer {
            service.debugConfigureAcceptedStackAuthTokenForTesting(nil)
        }

        let request = MobileHostRPCRequest(
            id: "workspace-list",
            method: "workspace.list",
            params: [:],
            auth: MobileHostRPCAuth(
                attachToken: nil,
                stackAccessToken: "cmux-dev-token"
            )
        )

        let result = await service.debugAuthorizationError(for: request)

        XCTAssertNil(result)
    }
    #endif

    func testMobileHostRPCRejectsInvalidParamsShape() {
        let data = Data(#"{"id":"bad-params","method":"workspace.list","params":[]}"#.utf8)

        let result = MobileHostRPCEnvelope.decodeRequest(data)

        guard case let .failure(error) = result else {
            return XCTFail("Invalid params shape should be rejected")
        }
        XCTAssertEqual(error.code, "invalid_request")
        XCTAssertEqual(error.message, "params must be an object")
    }

    func testMobileHostRPCRejectsInvalidAuthShape() {
        let data = Data(#"{"id":"bad-auth","method":"workspace.list","auth":"token"}"#.utf8)

        let result = MobileHostRPCEnvelope.decodeRequest(data)

        guard case let .failure(error) = result else {
            return XCTFail("Invalid auth shape should be rejected")
        }
        XCTAssertEqual(error.code, "invalid_request")
        XCTAssertEqual(error.message, "auth must be an object")
    }

    func testMobileHostRPCIgnoresRefreshTokenOnlyAuth() {
        let data = Data(#"{"id":"refresh-only","method":"workspace.list","auth":{"stack_refresh_token":"secret"}}"#.utf8)

        let result = MobileHostRPCEnvelope.decodeRequest(data)

        guard case let .success(request) = result else {
            return XCTFail("Refresh-token-only auth should decode as an unauthenticated request")
        }
        XCTAssertNil(request.auth)
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

    func testMobileRouteResolverImmediateSnapshotUsesNumericTailscaleFallbackWithoutDNS() throws {
        let resolver = MobileRouteResolver()

        let snapshot = resolver.routes(
            port: 61234,
            immediateHosts: {
                ["100.71.210.41"]
            }
        )

        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        XCTAssertEqual(tailscaleRoutes.count, 1)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            XCTAssertEqual(host, "100.71.210.41")
            XCTAssertEqual(port, 61234)
        } else {
            XCTFail("Expected immediate snapshot to include a numeric Tailscale route")
        }
        XCTAssertEqual(snapshot.routes.filter { $0.kind == .debugLoopback }.count, 1)
    }

    func testMobileRouteResolverAwaitsMagicDNSForPublicStatusRoutes() async throws {
        let resolver = MobileRouteResolver()

        let snapshot = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                [
                    "work-mac.tailnet.ts.net",
                    "100.71.210.41",
                ]
            }
        )

        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        XCTAssertEqual(tailscaleRoutes.count, 2)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            XCTAssertEqual(host, "work-mac.tailnet.ts.net")
            XCTAssertEqual(port, 61234)
        } else {
            XCTFail("Expected public status route to wait for MagicDNS")
        }
    }

    func testMobileRouteResolverRefreshesStalePublicStatusRoutes() async throws {
        let resolver = MobileRouteResolver()
        let now = Date()

        _ = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                [
                    "old-mac.tailnet.ts.net",
                    "100.71.210.41",
                ]
            },
            now: now
        )
        let refreshed = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                [
                    "new-mac.tailnet.ts.net",
                    "100.71.210.42",
                ]
            },
            now: now.addingTimeInterval(31)
        )

        let tailscaleRoutes = refreshed.routes.filter { $0.kind == .tailscale }
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            XCTAssertEqual(host, "new-mac.tailnet.ts.net")
            XCTAssertEqual(port, 61234)
        } else {
            XCTFail("Expected stale public status routes to refresh")
        }
    }

    func testMobileRouteResolverRetriesAfterIPOnlyPublicStatusRoutes() async throws {
        let resolver = MobileRouteResolver()
        let now = Date()

        _ = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                ["100.71.210.41"]
            },
            now: now
        )
        let refreshed = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                [
                    "work-mac.tailnet.ts.net",
                    "100.71.210.41",
                ]
            },
            now: now.addingTimeInterval(1)
        )

        let tailscaleRoutes = refreshed.routes.filter { $0.kind == .tailscale }
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            XCTAssertEqual(host, "work-mac.tailnet.ts.net")
            XCTAssertEqual(port, 61234)
        } else {
            XCTFail("Expected IP-only public status routes to retry MagicDNS resolution")
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
                stackAccessToken: nil
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
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        XCTAssertEqual(error?.code, "forbidden")
    }

    func testAttachTicketAcceptsUnscopedWorkspaceListForPairedDevice() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal")
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

        XCTAssertNil(error)
    }

    func testTerminalScopedAttachTicketAcceptsScopedWorkspaceList() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal")
        let request = MobileHostRPCRequest(
            id: "workspace-list",
            method: "workspace.list",
            params: [
                "workspace_id": "workspace",
                "terminal_id": "terminal",
            ],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        XCTAssertNil(error)
    }

    func testAttachTicketAcceptsTerminalCreateForPairedDevice() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal")
        let request = MobileHostRPCRequest(
            id: "terminal-create",
            method: "terminal.create",
            params: [
                "workspace_id": "other-workspace",
            ],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        XCTAssertNil(error)
    }

    func testWorkspaceScopedAttachTicketAcceptsTerminalCreate() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: nil)
        let request = MobileHostRPCRequest(
            id: "terminal-create",
            method: "terminal.create",
            params: ["workspace_id": "workspace"],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        XCTAssertNil(error)
    }

    func testTerminalScopedAttachTicketRejectsConflictingTerminalAliases() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal-a")
        let request = MobileHostRPCRequest(
            id: "workspace-list",
            method: "workspace.list",
            params: [
                "workspace_id": "workspace",
                "surface_id": "terminal-a",
                "terminal_id": "terminal-b",
            ],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
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
                stackAccessToken: nil
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

    func testMobileHostConnectionCloseLeavesViewportReportsToTTL() {
        let service = MobileHostService.shared
        let connectionID = UUID()

        service.debugResetMobileLifecycleStateForTesting()
        service.debugRecordClientIDForTesting("ios-client", connectionID: connectionID)

        XCTAssertEqual(service.debugTrackedClientIDsForTesting(connectionID: connectionID), Set(["ios-client"]))

        service.debugRemoveConnectionForTesting(id: connectionID)

        XCTAssertNil(service.debugTrackedClientIDsForTesting(connectionID: connectionID))
    }

    func testMobileHostIgnoresStaleListenerStateCallbacks() {
        let service = MobileHostService.shared
        let currentGeneration = UUID()
        let staleGeneration = UUID()

        service.debugResetMobileLifecycleStateForTesting()
        service.debugSetListenerStateForTesting(
            generation: currentGeneration,
            usesEphemeralFallback: true,
            port: 61234
        )

        service.debugHandleListenerStateForTesting(
            .failed(.posix(.ECONNRESET)),
            generation: staleGeneration
        )

        XCTAssertEqual(service.debugListenerGenerationForTesting(), currentGeneration)
        XCTAssertTrue(service.debugListenerUsesEphemeralFallbackForTesting())
        XCTAssertEqual(service.debugListenerPortForTesting(), 61234)

        service.debugHandleListenerStateForTesting(.cancelled, generation: staleGeneration)

        XCTAssertEqual(service.debugListenerGenerationForTesting(), currentGeneration)
        XCTAssertTrue(service.debugListenerUsesEphemeralFallbackForTesting())
        XCTAssertEqual(service.debugListenerPortForTesting(), 61234)
    }

    func testMobileHostWaitingListenerDoesNotPublishRoutes() {
        let service = MobileHostService.shared
        let generation = UUID()

        service.stop()
        service.debugResetMobileLifecycleStateForTesting()
        service.debugSetListenerStateForTesting(
            generation: generation,
            usesEphemeralFallback: false,
            port: 61234
        )

        service.debugHandleListenerStateForTesting(.waiting(.posix(.EADDRINUSE)), generation: generation)

        let status = service.statusSnapshot()
        XCTAssertFalse(status.isRunning)
        XCTAssertNil(status.port)
        XCTAssertTrue(status.routes.isEmpty)
        XCTAssertNil(service.debugListenerPortForTesting())
    }

    func testMobileHostConnectionClosesWhenFirstFrameTimesOut() async throws {
        let connectionID = UUID()
        let recorder = MobileHostConnectionCloseRecorder()
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 9)!,
            using: .tcp
        )
        let session = MobileHostConnection(
            id: connectionID,
            connection: connection,
            firstFrameTimeoutNanoseconds: 1_000_000,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { id in
                await recorder.record(id)
            }
        )

        await session.debugStartFirstFrameTimeoutForTesting()

        for _ in 0..<100 {
            let recordedIDs = await recorder.recordedIDs()
            if !recordedIDs.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let finalRecordedIDs = await recorder.recordedIDs()
        XCTAssertEqual(finalRecordedIDs, [connectionID])
    }

    func testMobileHostConnectionClosesWhenIdleAfterFirstFrame() async throws {
        let connectionID = UUID()
        let recorder = MobileHostConnectionCloseRecorder()
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 9)!,
            using: .tcp
        )
        let session = MobileHostConnection(
            id: connectionID,
            connection: connection,
            idleTimeoutNanoseconds: 1_000_000,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { id in
                await recorder.record(id)
            }
        )

        await session.debugStartIdleTimeoutAfterFrameForTesting()

        for _ in 0..<100 {
            let recordedIDs = await recorder.recordedIDs()
            if !recordedIDs.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let finalRecordedIDs = await recorder.recordedIDs()
        XCTAssertEqual(finalRecordedIDs, [connectionID])
    }

    func testMobileHostConnectionStopsBatchedFrameProcessingAfterClose() async throws {
        let connectionID = UUID()
        let requestRecorder = MobileHostConnectionRequestRecorder()
        let sessionBox = MobileHostConnectionBox()
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 9)!,
            using: .tcp
        )
        let session = MobileHostConnection(
            id: connectionID,
            connection: connection,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { request in
                await requestRecorder.record(request)
                await sessionBox.close(reason: "test close after first batched frame")
            },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        await sessionBox.set(session)

        let firstFrame = try MobileSyncFrameCodec.encodeFrame(
            Data(#"{"id":"first","method":"workspace.list","params":{}}"#.utf8)
        )
        let secondFrame = try MobileSyncFrameCodec.encodeFrame(
            Data(#"{"id":"second","method":"terminal.input","params":{"text":"should-not-run"}}"#.utf8)
        )
        var batch = Data()
        batch.append(firstFrame)
        batch.append(secondFrame)

        await session.debugHandleReceiveDataForTesting(batch)

        let recordedMethods = await requestRecorder.recordedMethods()
        XCTAssertEqual(recordedMethods, ["workspace.list"])
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

private actor MobileHostConnectionCloseRecorder {
    private var ids: [UUID] = []

    func record(_ id: UUID) {
        ids.append(id)
    }

    func recordedIDs() -> [UUID] {
        ids
    }
}

private actor MobileHostConnectionRequestRecorder {
    private var methods: [String] = []

    func record(_ request: MobileHostRPCRequest) {
        methods.append(request.method)
    }

    func recordedMethods() -> [String] {
        methods
    }
}

private actor MobileHostConnectionBox {
    private var session: MobileHostConnection?

    func set(_ session: MobileHostConnection) {
        self.session = session
    }

    func close(reason: String) async {
        await session?.close(reason: reason)
    }
}
