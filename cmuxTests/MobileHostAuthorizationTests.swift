import CMUXMobileCore
import Foundation
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

    func testAttachTicketStoreRecordsCreatedResourceScopes() throws {
        let store = MobileAttachTicketStore()
        let route = try CmxAttachRoute(
            id: "debug",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58465)
        )
        let ticket = try store.createTicket(
            workspaceID: "workspace",
            terminalID: "terminal",
            routes: [route],
            ttl: 3600
        )

        store.recordCreatedResources(
            authToken: ticket.authToken,
            workspaceID: "created-workspace",
            terminalID: "created-terminal"
        )

        let authorization = try XCTUnwrap(store.validAuthorization(authToken: ticket.authToken))
        XCTAssertEqual(authorization.createdWorkspaceIDs, Set(["created-workspace"]))
        XCTAssertEqual(authorization.createdTerminalIDs, Set(["created-terminal"]))
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

    /// The unauthenticated status verb may trigger Stack network verification
    /// for token-bearing requests, so the lookups it can have in flight are
    /// hard-capped: saturated acquires fail fast (the reply degrades to
    /// identity-free) instead of queueing attacker-minted token lookups, and
    /// a released slot is immediately reusable.
    func testStatusVerificationLimiterCapsInFlightLookups() async {
        let limiter = MobileHostStatusVerificationLimiter(limit: 2)

        let first = await limiter.acquire()
        let second = await limiter.acquire()
        let saturated = await limiter.acquire()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertFalse(saturated)

        await limiter.release()
        let afterRelease = await limiter.acquire()
        XCTAssertTrue(afterRelease)
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

    func testMobileRouteResolverNotifiesCallbackForInFlightMagicDNSRefresh() async throws {
        let resolver = MobileRouteResolver()
        let started = expectation(description: "refresh started")
        let callback = expectation(description: "refresh callback")
        let startedBox = SendableExpectation(started)
        let callbackBox = SendableExpectation(callback)
        let gate = SendableSemaphore(value: 0)
        let observedHosts = LockedHosts()

        resolver.refreshTailscaleRoutes(
            resolveHosts: {
                startedBox.fulfill()
                gate.wait()
                return [
                    "work-mac.tailnet.ts.net",
                    "100.71.210.41",
                ]
            }
        )
        await fulfillment(of: [started], timeout: 1)

        resolver.refreshTailscaleRoutes(
            resolveHosts: {
                ["unused.tailnet.ts.net"]
            },
            onResolvedHosts: { hosts in
                observedHosts.set(hosts)
                callbackBox.fulfill()
            }
        )

        gate.signal()
        await fulfillment(of: [callback], timeout: 1)
        XCTAssertEqual(observedHosts.value(), [
            "work-mac.tailnet.ts.net",
            "100.71.210.41",
        ])

        let snapshot = resolver.routes(port: 61234, immediateHosts: { [] })
        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        if case let .hostPort(host, _) = tailscaleRoutes.first?.endpoint {
            XCTAssertEqual(host, "work-mac.tailnet.ts.net")
        } else {
            XCTFail("Expected callback refresh to populate the MagicDNS route")
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

    func testAttachTicketAcceptsWorkspaceCreateForPairedDevice() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal")
        let request = MobileHostRPCRequest(
            id: "workspace-create",
            method: "workspace.create",
            params: [:],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        XCTAssertNil(error)
    }

    func testAttachTicketAcceptsReplayForCreatedWorkspace() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal")
        let request = MobileHostRPCRequest(
            id: "terminal-replay",
            method: "terminal.replay",
            params: [
                "workspace_id": "created-workspace",
                "surface_id": "created-terminal",
            ],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(
            ticket: ticket,
            request: request,
            createdWorkspaceIDs: ["created-workspace"]
        )

        XCTAssertNil(error)
    }

    func testAttachTicketAcceptsReplayForCreatedTerminal() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal")
        let request = MobileHostRPCRequest(
            id: "terminal-replay",
            method: "terminal.replay",
            params: [
                "workspace_id": "other-workspace",
                "surface_id": "created-terminal",
            ],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(
            ticket: ticket,
            request: request,
            createdTerminalIDs: ["created-terminal"]
        )

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

    func testScopedAttachTicketAcceptsNamedTerminalReplay() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal")
        let request = MobileHostRPCRequest(
            id: "terminal-replay",
            method: "terminal.replay",
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

    func testTerminalScopedAttachTicketRejectsDifferentTerminalInput() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal")
        let request = MobileHostRPCRequest(
            id: "terminal-input",
            method: "terminal.input",
            params: [
                "workspace_id": "workspace",
                "surface_id": "other-terminal",
                "text": "x",
            ],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        XCTAssertEqual(error?.code, "forbidden")
    }

    func testTerminalScopedAttachTicketRejectsUnscopedTerminalReplay() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal")
        let request = MobileHostRPCRequest(
            id: "terminal-replay",
            method: "terminal.replay",
            params: [:],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        XCTAssertEqual(error?.code, "forbidden")
    }

    func testWorkspaceScopedAttachTicketRejectsTerminalReplayOutsideWorkspace() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: nil)
        let request = MobileHostRPCRequest(
            id: "terminal-replay",
            method: "terminal.replay",
            params: [
                "workspace_id": "other-workspace",
                "surface_id": "terminal",
            ],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        XCTAssertEqual(error?.code, "forbidden")
    }

    func testWorkspaceScopedAttachTicketAcceptsTerminalReplayInWorkspace() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: nil)
        let request = MobileHostRPCRequest(
            id: "terminal-replay",
            method: "terminal.replay",
            params: [
                "workspace_id": "workspace",
                "surface_id": "terminal",
            ],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )

        let error = MobileHostService.debugTicketAuthorizationError(ticket: ticket, request: request)

        XCTAssertNil(error)
    }

    func testMacScopedAttachTicketAcceptsTerminalReplayInAnyWorkspace() throws {
        let ticket = try scopedAttachTicket(workspaceID: "", terminalID: nil)
        let request = MobileHostRPCRequest(
            id: "terminal-replay",
            method: "terminal.replay",
            params: [
                "workspace_id": "other-workspace",
                "surface_id": "other-terminal",
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

    func testMobileHostConnectionCloseOnlyClearsConnectionTracking() {
        let service = MobileHostService.shared
        let connectionID = UUID()

        service.debugResetMobileLifecycleStateForTesting()
        service.debugRecordClientIDForTesting("ios-client", connectionID: connectionID)

        XCTAssertEqual(service.debugTrackedClientIDsForTesting(connectionID: connectionID), Set(["ios-client"]))

        service.debugRemoveConnectionForTesting(id: connectionID)

        XCTAssertNil(service.debugTrackedClientIDsForTesting(connectionID: connectionID))
    }

    func testIdleMobileConnectionDoesNotKeepRequestActivityBusy() {
        MobileHostRequestActivity.resetForTesting()
        MobileHostRequestActivity.beginConnection()
        defer {
            MobileHostRequestActivity.endConnection()
            MobileHostRequestActivity.resetForTesting()
        }

        XCTAssertFalse(MobileHostRequestActivity.hasActiveRequest)
        XCTAssertFalse(MobileHostRequestActivity.hasRecentActivity(within: 60))
        XCTAssertEqual(MobileHostRequestActivity.quietDelay(for: 60), 0)
    }

    func testMobileHostConnectionCloseLeavesViewportReportsForPollingClient() {
        let service = MobileHostService.shared
        let terminalController = TerminalController.shared
        let connectionID = UUID()
        let surfaceID = UUID()

        service.debugResetMobileLifecycleStateForTesting()
        terminalController.debugResetMobileViewportReportsForTesting()
        terminalController.debugSetMobileViewportReportForTesting(
            surfaceID: surfaceID,
            clientID: "ios-client",
            columns: 54,
            rows: 42
        )
        terminalController.debugSetMobileViewportReportForTesting(
            surfaceID: surfaceID,
            clientID: "ipad-client",
            columns: 84,
            rows: 15
        )
        service.debugRecordClientIDForTesting("ios-client", connectionID: connectionID)

        service.debugRemoveConnectionForTesting(id: connectionID)

        XCTAssertEqual(
            terminalController.debugMobileViewportReportClientIDsForTesting(surfaceID: surfaceID),
            Set(["ios-client", "ipad-client"]),
            "Mobile RPC connections are short lived, so socket close must not clear viewport reports before their TTL expires."
        )

        terminalController.debugResetMobileViewportReportsForTesting()
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

    func testMobileHostConnectionKeepsSubscribedEventStreamPastIdleTimeout() async throws {
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

        await session.subscribe(streamID: "events", topics: ["terminal.updated"])
        await session.debugStartIdleTimeoutAfterFrameForTesting()
        try await Task.sleep(nanoseconds: 25_000_000)
        let subscribedCloseIDs = await recorder.recordedIDs()
        XCTAssertTrue(subscribedCloseIDs.isEmpty)

        _ = await session.unsubscribe(streamID: "events")
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

    func testTerminalRenderObserverRetainsGhosttyDemandOnlyWithTerminalSubscriber() async throws {
        let service = MobileHostService.shared
        service.debugResetMobileLifecycleStateForTesting()
        let observer = MobileTerminalRenderObserver.shared
        observer.stop()
        observer.start()
        defer {
            observer.stop()
            service.debugResetMobileLifecycleStateForTesting()
        }

        drainMobileHostMainQueue()
        XCTAssertFalse(MobileHostService.debugHasEventSubscribersForTesting(topic: "terminal.updated"))
        XCTAssertFalse(observer.debugIsRetainingNotificationDemandForTesting)

        let session = MobileHostConnection(
            id: UUID(),
            connection: NWConnection(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: 9)!,
                using: .tcp
            ),
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )

        await session.subscribe(streamID: "events", topics: ["terminal.updated"])
        drainMobileHostMainQueue()

        XCTAssertTrue(MobileHostService.debugHasEventSubscribersForTesting(topic: "terminal.updated"))
        XCTAssertTrue(observer.debugIsRetainingNotificationDemandForTesting)

        _ = await session.unsubscribe(streamID: "events")
        drainMobileHostMainQueue()

        XCTAssertFalse(MobileHostService.debugHasEventSubscribersForTesting(topic: "terminal.updated"))
        XCTAssertFalse(observer.debugIsRetainingNotificationDemandForTesting)
    }

    func testMobileWorkspaceListHashIncludesDisplayedDirectories() {
        let workspace = Workspace(
            title: "Mobile",
            workingDirectory: "/tmp/mobile-a",
            portOrdinal: 0
        )
        let initial = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        workspace.currentDirectory = "/tmp/mobile-b"
        let afterWorkspaceDirectory = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        XCTAssertNotEqual(initial, afterWorkspaceDirectory)

        workspace.panelDirectories[UUID()] = "/tmp/mobile-terminal"
        let afterTerminalDirectory = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        XCTAssertNotEqual(afterWorkspaceDirectory, afterTerminalDirectory)
    }

    func testMobileHostConnectionDoesNotPersistUnauthorizedEventSubscription() async throws {
        let connectionID = UUID()
        let recorder = MobileHostConnectionCloseRecorder()
        let socket = try MobileHostStartedTestSocket()
        defer { socket.close() }
        let session = MobileHostConnection(
            id: connectionID,
            connection: socket.connection,
            idleTimeoutNanoseconds: 1_000_000,
            authorizeRequest: { _ in
                .failure(MobileHostRPCError(code: "unauthorized", message: "no"))
            },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { id in
                await recorder.record(id)
            }
        )
        let frame = try MobileSyncFrameCodec.encodeFrame(
            Data(#"{"id":"subscribe","method":"mobile.events.subscribe","params":{"stream_id":"events","topics":["terminal.updated"]}}"#.utf8)
        )

        await session.debugHandleReceiveDataForTesting(frame)
        try await Task.sleep(nanoseconds: 25_000_000)
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
            authorizeRequest: { request in
                if request.id as? String == "second" {
                    do {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    } catch {}
                }
                return nil
            },
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

        for _ in 0..<100 {
            let recordedMethods = await requestRecorder.recordedMethods()
            if !recordedMethods.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let recordedMethods = await requestRecorder.recordedMethods()
        XCTAssertEqual(recordedMethods, ["workspace.list"])
    }

    // MARK: - Advertised mobile host capabilities

    func testMobileHostAdvertisesWorkspaceActionsCapability() {
        // The iOS client gates rename/pin on `workspace.actions.v1`; every
        // mobile.host.status path reads this single list, so advertising it here
        // is what makes the feature visible to a supporting Mac.
        let capabilities = MobileHostService.mobileHostCapabilities
        XCTAssertTrue(capabilities.contains("workspace.actions.v1"))
        XCTAssertTrue(capabilities.contains("terminal.render_grid.v1"))
    }

    // MARK: - Mobile workspace.action sub-action gate

    func testMobileWorkspaceActionGateAllowsOnlyPinUnpinRename() {
        for action in ["pin", "unpin", "rename", "PIN", "UnPin", "RENAME"] {
            XCTAssertTrue(
                TerminalController.mobileAllowsWorkspaceAction(action),
                "mobile workspace.action '\(action)' should be allowed"
            )
        }
        for action in [
            "move_up", "move-down", "move_top",
            "close_others", "close_above", "close_below",
            "set_color", "clear_color", "set_description", "clear_description",
            "clear_name", "mark_read", "mark_unread", "self_destruct", "",
        ] {
            XCTAssertFalse(
                TerminalController.mobileAllowsWorkspaceAction(action),
                "mobile workspace.action '\(action)' must be rejected"
            )
        }
        XCTAssertFalse(TerminalController.mobileAllowsWorkspaceAction(nil))
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

    private func drainMobileHostMainQueue() {
        let expectation = XCTestExpectation(description: "drain mobile host main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        XCTWaiter().wait(for: [expectation], timeout: 1)
    }
}

private enum MobileHostStartedTestSocketError: Error {
    case listenerPortUnavailable
    case listenerNotReady
    case connectionNotReady
}

private final class MobileHostStartedTestSocket: @unchecked Sendable {
    let connection: NWConnection
    private let listener: NWListener
    private let queue: DispatchQueue

    init() throws {
        let queue = DispatchQueue(label: "dev.cmux.mobile-host-started-test-socket")
        let listener = try NWListener(using: .tcp, on: .any)
        let listenerReady = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                listenerReady.signal()
            }
        }
        listener.newConnectionHandler = { serverConnection in
            serverConnection.start(queue: queue)
        }
        listener.start(queue: queue)
        guard listenerReady.wait(timeout: .now() + 2) == .success else {
            listener.cancel()
            throw MobileHostStartedTestSocketError.listenerNotReady
        }
        guard let port = listener.port else {
            listener.cancel()
            throw MobileHostStartedTestSocketError.listenerPortUnavailable
        }

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: .tcp
        )
        let connectionReady = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connectionReady.signal()
            }
        }
        connection.start(queue: queue)
        guard connectionReady.wait(timeout: .now() + 2) == .success else {
            connection.cancel()
            listener.cancel()
            throw MobileHostStartedTestSocketError.connectionNotReady
        }

        self.listener = listener
        self.connection = connection
        self.queue = queue
    }

    func close() {
        connection.cancel()
        listener.cancel()
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

private final class SendableExpectation: @unchecked Sendable {
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        expectation.fulfill()
    }
}

private final class SendableSemaphore: @unchecked Sendable {
    private let semaphore: DispatchSemaphore

    init(value: Int) {
        semaphore = DispatchSemaphore(value: value)
    }

    func wait() {
        semaphore.wait()
    }

    func signal() {
        semaphore.signal()
    }
}

private final class LockedHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []

    func set(_ nextHosts: [String]) {
        lock.lock()
        hosts = nextHosts
        lock.unlock()
    }

    func value() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }
}
