import CMUXMobileCore
import CmuxIrohTransport
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
    @Test func testLiveAuthorizationRejectsWorkspaceScopedAttachTokenForMacScopedMutations() async throws {
        let service = MobileHostService.shared
        service.debugConfigureAcceptedStackAuthTokenForTesting("cmux-dev-token")
        service.debugSetListenerStateForTesting(generation: UUID(), usesEphemeralFallback: false, port: 61234)
        defer { service.debugConfigureAcceptedStackAuthTokenForTesting(nil); service.debugSetListenerStateForTesting(generation: UUID(), usesEphemeralFallback: false, port: nil) }
        let payload = try await service.createAttachTicket(workspaceID: "workspace-main", terminalID: nil, ttl: 3600)
        let ticketPayload = try #require(payload["ticket"] as? [String: Any])
        let attachToken = try #require(ticketPayload["auth_token"] as? String)
        for (method, params) in [
            ("workspace.create", ["group_id": "group-main"]),
            ("workspace.move", ["workspace_id": "workspace-main", "before_workspace_id": "workspace-next"]),
            (
                "workspace.group.action",
                ["group_id": "group-main", "action": "rename"]
            ),
        ] {
            let request = MobileHostRPCRequest(
                id: method,
                method: method,
                params: params,
                auth: MobileHostRPCAuth(attachToken: attachToken, stackAccessToken: "cmux-dev-token")
            )
            let result = await service.debugAuthorizationError(for: request)
            guard case let .failure(error) = result else {
                return #expect(Bool(false), "workspace-scoped attach token should reject \(method)")
            }
            #expect(error.code == "forbidden")
        }
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
    @Test func testMobileRouteResolverPublishesOnlyNumericTailscaleAddresses() throws {
        let resolver = MobileRouteResolver()
        let snapshot = resolver.routes(
            port: 61234,
            tailscaleHosts: [
                "work-mac.tailnet.ts.net",
                "100.71.210.41",
                "fd7a:115c:a1e0::1234",
                "203.0.113.10",
            ]
        )
        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        #expect(tailscaleRoutes.count == 2)
        #expect(tailscaleRoutes.first?.priority == 10)
        #expect(tailscaleRoutes.last?.priority == 20)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "100.71.210.41")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected first numeric Tailscale route")
        }
        if case let .hostPort(host, port) = tailscaleRoutes.last?.endpoint {
            #expect(host == "fd7a:115c:a1e0::1234")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected IPv6 Tailscale route")
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
        #expect(tailscaleRoutes.count == 1)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "100.71.210.41")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected public status to publish the numeric Tailscale route")
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
            #expect(host == "100.71.210.42")
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
            #expect(host == "100.71.210.41")
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
            #expect(host == "100.71.210.41")
        } else {
            #expect(Bool(false), "Expected callback refresh to populate the numeric route")
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
        #expect(error == nil)
    }
    @Test func testAttachTicketAcceptsMacDirectoryListForPairedDevice() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace", terminalID: "terminal")
        let request = MobileHostRPCRequest(
            id: "directory-list",
            method: "mobile.directory.list",
            params: [
                "path": "~",
                "offset": 0,
                "limit": 50,
            ],
            auth: MobileHostRPCAuth(
                attachToken: ticket.authToken,
                stackAccessToken: nil
            )
        )
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
        #expect(error == nil)
    }
    @Test func testWorkspaceMoveRejectsForeignWorkspaceForWorkspaceScopedTicket() throws {
        let error = try workspaceMoveAuthorizationError(
            ticketWorkspaceID: "workspace",
            workspaceID: "other-workspace",
            params: ["before_workspace_id": "workspace"]
        )
        #expect(error?.code == "forbidden")
    }
    @Test func testWorkspaceMoveRejectsMatchingWorkspaceForWorkspaceScopedTicket() throws {
        let error = try workspaceMoveAuthorizationError(
            ticketWorkspaceID: "workspace",
            workspaceID: "workspace",
            params: ["before_workspace_id": "other-workspace"]
        )
        #expect(error?.code == "forbidden")
    }
    @Test func testWorkspaceMoveRejectsCreatedWorkspaceForWorkspaceScopedTicket() throws {
        let error = try workspaceMoveAuthorizationError(
            ticketWorkspaceID: "workspace",
            workspaceID: "created-workspace",
            params: ["group_id": "group"],
            createdWorkspaceIDs: ["created-workspace"]
        )
        #expect(error?.code == "forbidden")
    }
    @Test func testWorkspaceMoveRejectsTrimmedWorkspaceScopedTicket() throws {
        let error = try workspaceMoveAuthorizationError(
            ticketWorkspaceID: " workspace ",
            workspaceID: "workspace",
            params: ["before_workspace_id": "other-workspace"]
        )
        #expect(error?.code == "forbidden")
    }
    @Test func testWorkspaceMoveTreatsWhitespaceTicketWorkspaceIDAsMacScoped() throws {
        let error = try workspaceMoveAuthorizationError(
            ticketWorkspaceID: "  ",
            workspaceID: "other-workspace",
            params: ["group_id": "group"]
        )
        #expect(error == nil)
    }
    @Test func testWorkspaceMoveAcceptsMacScopedTicket() throws {
        let error = try workspaceMoveAuthorizationError(
            ticketWorkspaceID: "",
            workspaceID: "other-workspace",
            params: ["group_id": "group"]
        )
        #expect(error == nil)
    }
    @Test func testWorkspaceGroupActionRejectsForeignGroupForWorkspaceScopedTicket() throws {
        let error = try workspaceGroupActionAuthorizationError(
            ticketWorkspaceID: "workspace",
            groupID: "group-foreign",
            action: "rename"
        )
        #expect(error?.code == "forbidden")
    }
    @Test func testWorkspaceGroupActionRejectsMatchingGroupForWorkspaceScopedTicket() throws {
        let error = try workspaceGroupActionAuthorizationError(
            ticketWorkspaceID: "workspace",
            groupID: "group-owned",
            action: "pin"
        )
        #expect(error?.code == "forbidden")
    }
    @Test func testWorkspaceGroupActionRejectsCreatedWorkspaceAnchorForWorkspaceScopedTicket() throws {
        let error = try workspaceGroupActionAuthorizationError(
            ticketWorkspaceID: "workspace",
            groupID: "group-created",
            action: "delete",
            createdWorkspaceIDs: ["created-workspace"]
        )
        #expect(error?.code == "forbidden")
    }
    @Test func testWorkspaceGroupActionAcceptsMacScopedTicket() throws {
        let error = try workspaceGroupActionAuthorizationError(
            ticketWorkspaceID: "",
            groupID: "group-foreign",
            action: "ungroup"
        )
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
        let error = MobileHostService.ticketAuthorizationError(
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
        let error = MobileHostService.ticketAuthorizationError(
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
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
        let error = MobileHostService.ticketAuthorizationError(ticket: ticket, request: request)
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
    private func scopedAttachTicket(workspaceID: String, terminalID: String?) throws -> CmxAttachTicket {
        let route = try CmxAttachRoute(id: "debug", kind: .debugLoopback, endpoint: .hostPort(host: "127.0.0.1", port: 58465))
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
    private func workspaceMoveAuthorizationError(
        ticketWorkspaceID: String,
        workspaceID: String,
        params additionalParams: [String: String],
        createdWorkspaceIDs: Set<String> = []
    ) throws -> MobileHostRPCError? {
        let ticket = try scopedAttachTicket(workspaceID: ticketWorkspaceID, terminalID: nil)
        var params = additionalParams
        params["workspace_id"] = workspaceID
        let request = MobileHostRPCRequest(id: "workspace-move", method: "workspace.move", params: params, auth: MobileHostRPCAuth(attachToken: ticket.authToken, stackAccessToken: nil))
        return MobileHostService.ticketAuthorizationError(
            ticket: ticket,
            request: request,
            createdWorkspaceIDs: createdWorkspaceIDs
        )
    }
    private func workspaceGroupActionAuthorizationError(
        ticketWorkspaceID: String,
        groupID: String,
        action: String,
        createdWorkspaceIDs: Set<String> = []
    ) throws -> MobileHostRPCError? {
        let ticket = try scopedAttachTicket(workspaceID: ticketWorkspaceID, terminalID: nil)
        let request = MobileHostRPCRequest(
            id: "workspace-group-action",
            method: "workspace.group.action",
            params: ["group_id": groupID, "action": action],
            auth: MobileHostRPCAuth(attachToken: ticket.authToken, stackAccessToken: nil)
        )
        return MobileHostService.ticketAuthorizationError(
            ticket: ticket,
            request: request,
            createdWorkspaceIDs: createdWorkspaceIDs
        )
    }
    func drainMobileHostMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
private enum MobileHostStartedTestSocketError: Error {
    case listenerPortUnavailable
    case listenerNotReady
    case connectionNotReady
}
final class MobileHostStartedTestSocket: @unchecked Sendable {
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
actor MobileHostConnectionCloseRecorder {
    private var ids: [UUID] = []
    func record(_ id: UUID) {
        ids.append(id)
    }
    func recordedIDs() -> [UUID] {
        ids
    }
}
actor MobileHostAuthorizationInvocationRecorder {
    private var invocations = 0
    func record() { invocations += 1 }
    func count() -> Int { invocations }
}
actor MobileHostConnectionRequestRecorder {
    private var methods: [String] = []
    func record(_ request: MobileHostRPCRequest) {
        methods.append(request.method)
    }
    func recordedMethods() -> [String] {
        methods
    }
}
actor MobileHostConnectionBox {
    private var session: MobileHostConnection?
    func set(_ session: MobileHostConnection) {
        self.session = session
    }
    func close(reason: String) async {
        await session?.close(reason: reason)
    }
}
actor RecordingMobileHostByteTransport: CmxByteTransport {
    private var sent: [Data] = []
    private var closeCount = 0

    func connect() async throws {}
    func receive() async throws -> Data? { nil }
    func send(_ data: Data) async throws { sent.append(data) }
    func close() async { closeCount += 1 }

    func waitForSentBufferCount(_ count: Int) async -> [Data] {
        for _ in 0..<1_000 {
            if sent.count >= count { return sent }
            await Task.yield()
        }
        return sent
    }

    func observedCloseCount() -> Int { closeCount }
}
private enum TestMobileHostIndependentEventWriterError: Error {
    case failed
}
actor TestMobileHostIndependentEventWriter: MobileHostIndependentEventWriting {
    enum Behavior: Sendable {
        case failAfterProbe
        case blockAfterProbe
    }

    private let behavior: Behavior
    private var sendCount = 0
    private var closeCount = 0
    private var blockedWaiter: CheckedContinuation<Void, any Error>?
    private var blockedProbeWaiter: CheckedContinuation<Bool, Never>?
    private let blockedStream: AsyncStream<Void>
    private let blockedContinuation: AsyncStream<Void>.Continuation
    private let blockedProbeStream: AsyncStream<Void>
    private let blockedProbeContinuation: AsyncStream<Void>.Continuation

    init(behavior: Behavior) {
        self.behavior = behavior
        let blocked = AsyncStream<Void>.makeStream()
        blockedStream = blocked.stream
        blockedContinuation = blocked.continuation
        let blockedProbe = AsyncStream<Void>.makeStream()
        blockedProbeStream = blockedProbe.stream
        blockedProbeContinuation = blockedProbe.continuation
    }

    func probe(_: Data) async -> Bool {
        if blockedWaiter != nil {
            blockedProbeContinuation.yield(())
            return await withCheckedContinuation { continuation in
                blockedProbeWaiter = continuation
            }
        }
        sendCount += 1
        return true
    }

    func send(_: Data) async throws {
        sendCount += 1
        switch behavior {
        case .failAfterProbe:
            throw TestMobileHostIndependentEventWriterError.failed
        case .blockAfterProbe:
            blockedContinuation.yield(())
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    blockedWaiter = continuation
                }
            } onCancel: {
                Task { await self.cancelBlockedSend() }
            }
        }
    }

    func reset() async {
        blockedWaiter?.resume(throwing: TestMobileHostIndependentEventWriterError.failed)
        blockedWaiter = nil
    }

    func close() async {
        closeCount += 1
        blockedWaiter?.resume(throwing: CancellationError())
        blockedWaiter = nil
        blockedProbeWaiter?.resume(returning: false)
        blockedProbeWaiter = nil
    }

    func blockedEvents() -> AsyncStream<Void> { blockedStream }
    func blockedProbeEvents() -> AsyncStream<Void> { blockedProbeStream }
    func observedSendCount() -> Int { sendCount }
    func observedCloseCount() -> Int { closeCount }

    func failBlockedSend() {
        blockedWaiter?.resume(throwing: TestMobileHostIndependentEventWriterError.failed)
        blockedWaiter = nil
    }

    func releaseBlockedProbe(result: Bool) {
        blockedProbeWaiter?.resume(returning: result)
        blockedProbeWaiter = nil
    }

    private func cancelBlockedSend() {
        blockedWaiter?.resume(throwing: CancellationError())
        blockedWaiter = nil
    }
}
struct ImmediateMobileHostIrohClock: CmxIrohRelayClock {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { instant }
    func sleep(until _: Date) async throws {}
}
actor BlockingMobileHostIrohSendStream: CmxIrohSendStream {
    private var sendWaiter: CheckedContinuation<Void, any Error>?
    private var resetCodes: [UInt64] = []
    private var wasReset = false

    func send(_: Data) async throws {
        guard !wasReset else {
            throw TestMobileHostIndependentEventWriterError.failed
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sendWaiter = continuation
            }
        } onCancel: {
            Task { await self.cancelSend() }
        }
    }

    func finish() async throws {}

    func reset(errorCode: UInt64) async {
        wasReset = true
        resetCodes.append(errorCode)
        sendWaiter?.resume(throwing: TestMobileHostIndependentEventWriterError.failed)
        sendWaiter = nil
    }

    func setPriority(_: Int32) async throws {}
    func observedResetCodes() -> [UInt64] { resetCodes }

    private func cancelSend() {
        sendWaiter?.resume(throwing: CancellationError())
        sendWaiter = nil
    }
}
actor ImmediateMobileHostIrohReceiveStream: CmxIrohReceiveStream {
    func receive(maximumByteCount _: Int) -> Data? { nil }
    func stop(errorCode _: UInt64) {}
}
private enum AsyncTestSignalError: Error {
    case timedOut
}
final class AsyncTestSignal: @unchecked Sendable {
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
final class SendableSemaphore: @unchecked Sendable {
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
