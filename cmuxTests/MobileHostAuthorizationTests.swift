import CMUXMobileCore
import Foundation
@preconcurrency import Network
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct MobileHostAuthorizationTests {
    @Test func testAttachTicketStoreKeepsMultipleTicketsForSameTerminal() throws {
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

        #expect(first.authToken != second.authToken)
        #expect(store.validTicket(authToken: first.authToken, now: now.addingTimeInterval(2))?.authToken == first.authToken)
        #expect(store.validTicket(authToken: second.authToken, now: now.addingTimeInterval(2))?.authToken == second.authToken)
    }
    @Test func testAttachTicketStoreRecordsCreatedResourceScopes() throws {
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

        let authorization = try #require(store.validAuthorization(authToken: ticket.authToken))
        #expect(authorization.createdWorkspaceIDs == Set(["created-workspace"]))
        #expect(authorization.createdTerminalIDs == Set(["created-terminal"]))
    }
    @Test func testMobileWorkspaceRPCRequiresAuthorization() async {
        let request = MobileHostRPCRequest(
            id: "workspace-list",
            method: "workspace.list",
            params: [:],
            auth: nil
        )

        let result = await MobileHostService.shared.debugAuthorizationError(for: request)

        guard case let .failure(error) = result else {
            return #expect(Bool(false), "workspace.list should require mobile authorization")
        }
        #expect(error.code == "unauthorized")
    }
    @Test func testMobileHostStatusDoesNotRequireAuthorization() async {
        let request = MobileHostRPCRequest(
            id: "host-status",
            method: "mobile.host.status",
            params: [:],
            auth: nil
        )

        let result = await MobileHostService.shared.debugAuthorizationError(for: request)

        #expect(result == nil)
    }

    #if DEBUG
    @Test func testDebugStackAuthTokenPolicyRequiresConfiguredToken() {
        #expect(MobileHostDevStackAuthPolicy.normalizedToken("   ") == nil)
        #expect(!MobileHostDevStackAuthPolicy.authorize(
            providedToken: "cmux-dev-token",
            acceptedToken: nil
        ))
        #expect(!MobileHostDevStackAuthPolicy.authorize(
            providedToken: "cmux-dev-token",
            acceptedToken: "other-token"
        ))
        #expect(MobileHostDevStackAuthPolicy.authorize(
            providedToken: " cmux-dev-token ",
            acceptedToken: "cmux-dev-token"
        ))
    }
    @Test func testDebugConfiguredStackAuthTokenAuthorizesBroadWorkspaceList() async {
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

        #expect(result == nil)
    }
    #endif
    @Test func testMobileHostRPCRejectsInvalidParamsShape() {
        let data = Data(#"{"id":"bad-params","method":"workspace.list","params":[]}"#.utf8)

        let result = MobileHostRPCEnvelope.decodeRequest(data)

        guard case let .failure(error) = result else {
            return #expect(Bool(false), "Invalid params shape should be rejected")
        }
        #expect(error.code == "invalid_request")
        #expect(error.message == "params must be an object")
    }
    @Test func testMobileHostRPCRejectsInvalidAuthShape() {
        let data = Data(#"{"id":"bad-auth","method":"workspace.list","auth":"token"}"#.utf8)

        let result = MobileHostRPCEnvelope.decodeRequest(data)

        guard case let .failure(error) = result else {
            return #expect(Bool(false), "Invalid auth shape should be rejected")
        }
        #expect(error.code == "invalid_request")
        #expect(error.message == "auth must be an object")
    }
    @Test func testMobileHostRPCIgnoresRefreshTokenOnlyAuth() {
        let data = Data(#"{"id":"refresh-only","method":"workspace.list","auth":{"stack_refresh_token":"secret"}}"#.utf8)

        let result = MobileHostRPCEnvelope.decodeRequest(data)

        guard case let .success(request) = result else {
            return #expect(Bool(false), "Refresh-token-only auth should decode as an unauthenticated request")
        }
        #expect(request.auth == nil)
    }
    @Test func testMobileRouteResolverPrefersTailscaleMagicDNSBeforeIPv4Fallback() throws {
        let resolver = MobileRouteResolver()

        let snapshot = resolver.routes(
            port: 61234,
            tailscaleHosts: [
                "work-mac.tailnet.ts.net",
                "100.71.210.41",
            ]
        )

        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        #expect(tailscaleRoutes.count == 2)
        #expect(tailscaleRoutes.first?.priority == 10)
        #expect(tailscaleRoutes.last?.priority == 20)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "work-mac.tailnet.ts.net")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected first Tailscale route to use a host/port endpoint")
        }
        if case let .hostPort(host, port) = tailscaleRoutes.last?.endpoint {
            #expect(host == "100.71.210.41")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected fallback Tailscale route to use a host/port endpoint")
        }
    }
    @Test func testMobileRouteResolverImmediateSnapshotUsesNumericTailscaleFallbackWithoutDNS() throws {
        let resolver = MobileRouteResolver()

        let snapshot = resolver.routes(
            port: 61234,
            immediateHosts: {
                ["100.71.210.41"]
            }
        )

        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        #expect(tailscaleRoutes.count == 1)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "100.71.210.41")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected immediate snapshot to include a numeric Tailscale route")
        }
        #expect(snapshot.routes.filter { $0.kind == .debugLoopback }.count == 1)
    }
    @Test func testMobileRouteResolverUsesManualHostWhenTailscaleIsUnavailable() throws {
        let resolver = MobileRouteResolver()

        let snapshot = resolver.routes(
            port: 61234,
            tailscaleHosts: [],
            manualHost: " studio-mac.corp.example "
        )

        let manualRoutes = snapshot.routes.filter { $0.kind == .manualHost }
        #expect(manualRoutes.count == 1)
        #expect(snapshot.routes.filter { $0.kind == .tailscale }.isEmpty)
        if case let .hostPort(host, port) = manualRoutes.first?.endpoint {
            #expect(host == "studio-mac.corp.example")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected manual host route to use a host/port endpoint")
        }
    }
    @Test func testMobileRouteResolverAwaitsMagicDNSForPublicStatusRoutes() async throws {
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
        #expect(tailscaleRoutes.count == 2)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "work-mac.tailnet.ts.net")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected public status route to wait for MagicDNS")
        }
    }
    @Test func testMobileRouteResolverRefreshesStalePublicStatusRoutes() async throws {
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
            #expect(host == "new-mac.tailnet.ts.net")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected stale public status routes to refresh")
        }
    }
    @Test func testMobileRouteResolverRetriesAfterIPOnlyPublicStatusRoutes() async throws {
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
            #expect(host == "work-mac.tailnet.ts.net")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected IP-only public status routes to retry MagicDNS resolution")
        }
    }
    @Test func testMobileRouteResolverNotifiesCallbackForInFlightMagicDNSRefresh() async throws {
        let resolver = MobileRouteResolver()
        let started = AsyncTestSignal()
        let callback = AsyncTestSignal()
        let gate = SendableSemaphore(value: 0)
        let observedHosts = LockedHosts()

        resolver.refreshTailscaleRoutes(
            resolveHosts: {
                started.fulfill()
                gate.wait()
                return [
                    "work-mac.tailnet.ts.net",
                    "100.71.210.41",
                ]
            }
        )
        try await started.wait()

        resolver.refreshTailscaleRoutes(
            resolveHosts: {
                ["unused.tailnet.ts.net"]
            },
            onResolvedHosts: { hosts in
                observedHosts.set(hosts)
                callback.fulfill()
            }
        )

        gate.signal()
        try await callback.wait()
        #expect(observedHosts.value() == [
            "work-mac.tailnet.ts.net",
            "100.71.210.41",
        ])

        let snapshot = resolver.routes(port: 61234, immediateHosts: { [] })
        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        if case let .hostPort(host, _) = tailscaleRoutes.first?.endpoint {
            #expect(host == "work-mac.tailnet.ts.net")
        } else {
            #expect(Bool(false), "Expected callback refresh to populate the MagicDNS route")
        }
    }
    @Test func testMobileAttachTicketCreateRequiresAuthorization() async {
        let request = MobileHostRPCRequest(
            id: "attach-ticket-create",
            method: "mobile.attach_ticket.create",
            params: [:],
            auth: nil
        )

        let result = await MobileHostService.shared.debugAuthorizationError(for: request)

        guard case let .failure(error) = result else {
            return #expect(Bool(false), "mobile.attach_ticket.create should require mobile authorization")
        }
        #expect(error.code == "unauthorized")
    }
    @Test func testScopedAttachTicketRejectsWorkspaceAliasIgnoredByHandlers() throws {
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

        #expect(error?.code == "forbidden")
    }
    @Test func testScopedAttachTicketRejectsTerminalAliasIgnoredByHandlers() throws {
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

        #expect(error?.code == "forbidden")
    }
    @Test func testAttachTicketAcceptsUnscopedWorkspaceListForPairedDevice() throws {
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

        #expect(error == nil)
    }
    @Test func testTerminalScopedAttachTicketAcceptsScopedWorkspaceList() throws {
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

        #expect(error == nil)
    }
    @Test func testAttachTicketAcceptsTerminalCreateForPairedDevice() throws {
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

        #expect(error == nil)
    }
    @Test func testAttachTicketAcceptsWorkspaceCreateForPairedDevice() throws {
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

        #expect(error == nil)
    }
    @Test func testAttachTicketAcceptsReplayForCreatedWorkspace() throws {
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

        #expect(error == nil)
    }
    @Test func testAttachTicketAcceptsReplayForCreatedTerminal() throws {
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

        #expect(error == nil)
    }
    @Test func testWorkspaceScopedAttachTicketAcceptsTerminalCreate() throws {
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

        #expect(error == nil)
    }
    @Test func testTerminalScopedAttachTicketRejectsConflictingTerminalAliases() throws {
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

        #expect(error?.code == "forbidden")
    }
    @Test func testScopedAttachTicketAcceptsHandlerParameterNames() throws {
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

        #expect(error == nil)
    }
    @Test func testScopedAttachTicketAcceptsNamedTerminalReplay() throws {
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

        #expect(error == nil)
    }
    @Test func testTerminalScopedAttachTicketRejectsDifferentTerminalInput() throws {
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

        #expect(error?.code == "forbidden")
    }
    @Test func testTerminalScopedAttachTicketRejectsUnscopedTerminalReplay() throws {
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

        #expect(error?.code == "forbidden")
    }
    @Test func testWorkspaceScopedAttachTicketRejectsTerminalReplayOutsideWorkspace() throws {
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

        #expect(error?.code == "forbidden")
    }
    @Test func testWorkspaceScopedAttachTicketAcceptsTerminalReplayInWorkspace() throws {
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

        #expect(error == nil)
    }
    @Test func testMacScopedAttachTicketAcceptsTerminalReplayInAnyWorkspace() throws {
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

        #expect(error == nil)
    }
    @Test func testStackUserIDAuthorizationRequiresSignedInMacUser() throws {
        #expect(throws: (any Error).self) {
            try MobileHostAuthorizationPolicy.authorizeStackUserID(
                localUserID: nil,
                remoteUserID: "user_123"
            )
        }
    }
    @Test func testStackUserIDAuthorizationRequiresMatchingUserID() throws {
        #expect(throws: (any Error).self) {
            try MobileHostAuthorizationPolicy.authorizeStackUserID(
                localUserID: "user_local",
                remoteUserID: "user_remote"
            )
        }

        try MobileHostAuthorizationPolicy.authorizeStackUserID(
            localUserID: " user_123 ",
            remoteUserID: "user_123"
        )
    }
    @Test func testMobileHostConnectionCloseOnlyClearsConnectionTracking() {
        let service = MobileHostService.shared
        let connectionID = UUID()

        service.debugResetMobileLifecycleStateForTesting()
        service.debugRecordClientIDForTesting("ios-client", connectionID: connectionID)

        #expect(service.debugTrackedClientIDsForTesting(connectionID: connectionID) == Set(["ios-client"]))

        service.debugRemoveConnectionForTesting(id: connectionID)

        #expect(service.debugTrackedClientIDsForTesting(connectionID: connectionID) == nil)
    }
    @Test func testIdleMobileConnectionDoesNotKeepRequestActivityBusy() {
        MobileHostRequestActivity.resetForTesting()
        MobileHostRequestActivity.beginConnection()
        defer {
            MobileHostRequestActivity.endConnection()
            MobileHostRequestActivity.resetForTesting()
        }

        #expect(!MobileHostRequestActivity.hasActiveRequest)
        #expect(!MobileHostRequestActivity.hasRecentActivity(within: 60))
        #expect(MobileHostRequestActivity.quietDelay(for: 60) == 0)
    }
    @Test func testMobileHostConnectionCloseClearsOnlyClosedClientViewportReports() {
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

        #expect(
            terminalController.debugMobileViewportReportClientIDsForTesting(surfaceID: surfaceID) == Set(["ipad-client"]),
            "Closing one mobile RPC connection should clear only that connection's viewport reports."
        )

        terminalController.debugResetMobileViewportReportsForTesting()
    }
    @Test func testMobileHostIgnoresStaleListenerStateCallbacks() {
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

        #expect(service.debugListenerGenerationForTesting() == currentGeneration)
        #expect(service.debugListenerUsesEphemeralFallbackForTesting())
        #expect(service.debugListenerPortForTesting() == 61234)

        service.debugHandleListenerStateForTesting(.cancelled, generation: staleGeneration)

        #expect(service.debugListenerGenerationForTesting() == currentGeneration)
        #expect(service.debugListenerUsesEphemeralFallbackForTesting())
        #expect(service.debugListenerPortForTesting() == 61234)
    }
    @Test func testMobileHostWaitingListenerDoesNotPublishRoutes() {
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
        #expect(!status.isRunning)
        #expect(status.port == nil)
        #expect(status.routes.isEmpty)
        #expect(service.debugListenerPortForTesting() == nil)
    }
    @Test func testMobileHostConnectionClosesWhenFirstFrameTimesOut() async throws {
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
        #expect(finalRecordedIDs == [connectionID])
    }
    @Test func testMobileHostConnectionClosesWhenIdleAfterFirstFrame() async throws {
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
        #expect(finalRecordedIDs == [connectionID])
    }
    @Test func testMobileHostConnectionKeepsSubscribedEventStreamPastIdleTimeout() async throws {
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
        // An active subscription suppresses the idle-after-frame timeout: the
        // arm path early-returns without scheduling any close. Awaiting an
        // actor-isolated round-trip on the connection guarantees the arm call
        // was fully processed and that the connection is still alive and
        // subscribed, so the recorder reflects the final state with no
        // wall-clock window to race.
        #expect(await session.isSubscribed(to: "terminal.updated"))
        let subscribedCloseIDs = await recorder.recordedIDs()
        #expect(subscribedCloseIDs.isEmpty)

        _ = await session.unsubscribe(streamID: "events")
        for _ in 0..<100 {
            let recordedIDs = await recorder.recordedIDs()
            if !recordedIDs.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let finalRecordedIDs = await recorder.recordedIDs()
        #expect(finalRecordedIDs == [connectionID])
    }
    @Test func testTerminalRenderObserverRetainsGhosttyDemandOnlyWithTerminalSubscriber() async throws {
        let service = MobileHostService.shared
        service.debugResetMobileLifecycleStateForTesting()
        let observer = MobileTerminalRenderObserver.shared
        observer.stop()
        observer.start()
        defer {
            observer.stop()
            service.debugResetMobileLifecycleStateForTesting()
        }

        await drainMobileHostMainQueue()
        #expect(!MobileHostService.debugHasEventSubscribersForTesting(topic: "terminal.updated"))
        #expect(!observer.debugIsRetainingNotificationDemandForTesting)

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
        await drainMobileHostMainQueue()

        #expect(MobileHostService.debugHasEventSubscribersForTesting(topic: "terminal.updated"))
        #expect(observer.debugIsRetainingNotificationDemandForTesting)

        _ = await session.unsubscribe(streamID: "events")
        await drainMobileHostMainQueue()

        #expect(!MobileHostService.debugHasEventSubscribersForTesting(topic: "terminal.updated"))
        #expect(!observer.debugIsRetainingNotificationDemandForTesting)
    }
    @Test func testMobileWorkspaceListHashIncludesDisplayedDirectories() {
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

        #expect(initial != afterWorkspaceDirectory)

        workspace.panelDirectories[UUID()] = "/tmp/mobile-terminal"
        let afterTerminalDirectory = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        #expect(afterWorkspaceDirectory != afterTerminalDirectory)
    }
    @Test func testMobileHostConnectionDoesNotPersistUnauthorizedEventSubscription() async throws {
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
        #expect(finalRecordedIDs == [connectionID])
    }
    @Test func testMobileHostConnectionStopsBatchedFrameProcessingAfterClose() async throws {
        let connectionID = UUID()
        let requestRecorder = MobileHostConnectionRequestRecorder()
        let sessionBox = MobileHostConnectionBox()
        // Deterministic ordering signals replace the former timing race: the
        // first frame's authorize records and closes the session, then fulfills
        // `firstRecorded`. The second frame's authorize blocks on `secondGate`
        // (held until close is confirmed) instead of a fixed 100ms sleep, so the
        // close provably lands before the second frame can proceed.
        let firstRecorded = AsyncTestSignal()
        let secondAuthorizeStarted = AsyncTestSignal()
        let secondAuthorizeFinished = AsyncTestSignal()
        let secondGate = SendableSemaphore(value: 0)
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
                    secondAuthorizeStarted.fulfill()
                    secondGate.wait()
                    secondAuthorizeFinished.fulfill()
                }
                return nil
            },
            onAuthorizedRequest: { request in
                await requestRecorder.record(request)
                await sessionBox.close(reason: "test close after first batched frame")
                firstRecorded.fulfill()
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

        // Wait for the first frame to record and close the connection, then
        // confirm the second frame's authorize is in flight before releasing it.
        try await firstRecorded.wait()
        try await secondAuthorizeStarted.wait()
        secondGate.signal()
        try await secondAuthorizeFinished.wait()
        // After the second authorize returns, `respond` re-checks `isClosed`
        // synchronously and drops the frame without recording it. An
        // actor-isolated round-trip flushes that synchronous tail so the
        // recorder reflects the final, settled state.
        _ = await session.isSubscribed(to: "terminal.updated")
        let recordedMethods = await requestRecorder.recordedMethods()
        #expect(recordedMethods == ["workspace.list"])
    }

    // MARK: - Advertised mobile host capabilities
    @Test func testMobileHostAdvertisesWorkspaceActionCapabilities() {
        let capabilities = MobileHostService.mobileHostCapabilities
        #expect(capabilities.contains("workspace.actions.v1"))
        #expect(capabilities.contains("workspace.read_state.v1"))
        #expect(capabilities.contains("workspace.close.v1"))
        #expect(capabilities.contains("terminal.render_grid.v1"))
    }

    // MARK: - Mobile workspace.action sub-action gate
    @Test func testMobileWorkspaceActionGateAllowsOnlyPinNameAndReadStateActions() {
        for action in ["pin", "unpin", "rename", "mark_read", "mark_unread", "PIN", "UnPin", "RENAME", "MARK_READ", "Mark_Unread"] {
            #expect(
                TerminalController.mobileAllowsWorkspaceAction(action),
                "mobile workspace.action '\(action)' should be allowed"
            )
        }
        for action in [
            "move_up", "move-down", "move_top",
            "close_others", "close_above", "close_below",
            "set_color", "clear_color", "set_description", "clear_description",
            "clear_name", "close", "self_destruct", "",
        ] {
            #expect(
                !TerminalController.mobileAllowsWorkspaceAction(action),
                "mobile workspace.action '\(action)' must be rejected"
            )
        }
        #expect(!TerminalController.mobileAllowsWorkspaceAction(nil))
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

    private func drainMobileHostMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
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

private enum AsyncTestSignalError: Error {
    case timedOut
}

private final class AsyncTestSignal: @unchecked Sendable {
    private let condition = NSCondition()
    private var fulfilled = false

    func fulfill() {
        condition.lock()
        fulfilled = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval = 1) async throws {
        try await Task.detached { [self] in
            try blockingWait(timeout: timeout)
        }.value
    }

    private func blockingWait(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !fulfilled {
            if !condition.wait(until: deadline) {
                throw AsyncTestSignalError.timedOut
            }
        }
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
