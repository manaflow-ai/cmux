import Foundation
import CMUXMobileCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct WebClientBridgeTests {
    @Test func bindAddressRejectsWildcardAndUnapprovedInterfaces() {
        #expect(WebClientBridgeBindAddress.validate("0.0.0.0") == .failure(.wildcard))
        #expect(WebClientBridgeBindAddress.validate("::") == .failure(.wildcard))
        #expect(WebClientBridgeBindAddress.validate("192.168.1.20") == .failure(.unsupported))
        guard case let .success(loopback) = WebClientBridgeBindAddress.validate("127.0.0.1") else {
            return #expect(Bool(false))
        }
        #expect(loopback.kind == .loopback)
        guard case let .success(tailscale) = WebClientBridgeBindAddress.validate("100.100.20.4") else {
            return #expect(Bool(false))
        }
        #expect(tailscale.kind == .tailscale)
    }

    @Test func protocolVersionMismatchIsRejectedBeforeRPCDispatch() {
        #expect(WebClientWebSocketTransport.validatesProtocol("cmux.web/1", version: 1))
        #expect(WebClientWebSocketTransport.validatesProtocol("cmux.web/1", version: nil))
        #expect(!WebClientWebSocketTransport.validatesProtocol("cmux.web/2", version: 1))
        #expect(!WebClientWebSocketTransport.validatesProtocol("cmux.web/1", version: 2))
    }

    @Test func ordinaryMobileEnvelopesMayOmitRepeatedProtocolMetadata() {
        #expect(WebClientWebSocketTransport.validatesMessageProtocol(["id": 1, "ok": true]))
        #expect(WebClientWebSocketTransport.validatesMessageProtocol(["kind": "event"]))
        #expect(WebClientWebSocketTransport.validatesMessageProtocol([
            "protocol": "cmux.web/1",
            "protocol_version": 1,
        ]))
        #expect(!WebClientWebSocketTransport.validatesMessageProtocol([
            "protocol": "cmux.web/2",
        ]))
        #expect(!WebClientWebSocketTransport.validatesMessageProtocol([
            "protocol_version": 2,
        ]))
    }

    @Test func unauthenticatedClientMessageBudgetIsSmall() {
        #expect(WebClientWebSocketTransport.maximumClientMessageByteCount == 4 * 1024)
        #expect(
            WebClientWebSocketTransport.maximumServerMessageByteCount
                > WebClientWebSocketTransport.maximumClientMessageByteCount
        )
    }

    @Test func originPolicyRejectsUntrustedLoopbackWebpages() throws {
        let policy = WebClientBridgeOriginPolicy(
            bindAddress: try WebClientBridgeBindAddress("127.0.0.1")
        )
        #expect(policy.allows(originHeader: "http://localhost:5173"))
        #expect(policy.allows(originHeader: "http://127.0.0.1:5173"))
        #expect(policy.allows(originHeader: "https://[::1]"))
        #expect(!policy.allows(originHeader: "https://attacker.example"))
        #expect(!policy.allows(originHeader: "null"))
        #expect(!policy.allows(originHeader: nil))
    }

    @Test func originPolicyAllowsPrivateTailscaleFrontends() throws {
        let policy = WebClientBridgeOriginPolicy(
            bindAddress: try WebClientBridgeBindAddress("100.100.20.4")
        )
        #expect(policy.allows(originHeader: "http://localhost:5173"))
        #expect(policy.allows(originHeader: "http://100.100.20.4"))
        #expect(policy.allows(originHeader: "https://my-mac.tail123.ts.net"))
        #expect(!policy.allows(originHeader: "http://my-mac.tail123.ts.net"))
        #expect(!policy.allows(originHeader: "https://my-mac.tail123.ts.net.attacker.example"))
    }

    @Test func eachGrantHasIndependentTokenAndRevocation() async throws {
        let store = WebClientGrantStore(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let first = try await store.issue(label: "phone")
        let second = try await store.issue(label: "laptop")
        #expect(first.token != second.token)
        #expect(await store.authenticate(token: first.token) == first.snapshot.id)
        #expect(await store.authenticate(token: second.token) == second.snapshot.id)

        #expect(await store.revoke(first.snapshot.id))
        #expect(!(await store.isActive(first.snapshot.id)))
        #expect(await store.isActive(second.snapshot.id))
        #expect(await store.authenticate(token: first.token) == nil)
        #expect(await store.authenticate(token: second.token) == second.snapshot.id)
    }

    @Test func revokedGrantCannotBeRevokedTwice() async throws {
        let store = WebClientGrantStore()
        let issued = try await store.issue(label: nil)
        #expect(await store.revoke(issued.snapshot.id))
        #expect(!(await store.revoke(issued.snapshot.id)))
    }

    @Test func unknownGrantIsNeverActive() async {
        let store = WebClientGrantStore()
        #expect(!(await store.isActive(UUID())))
    }

    @Test func grantLabelIsBoundedByUnicodeScalarCount() async throws {
        let store = WebClientGrantStore()
        let combiningLabel = "a" + String(repeating: "\u{0301}", count: 500)
        let issued = try await store.issue(label: combiningLabel)
        #expect(issued.snapshot.label.unicodeScalars.count == 80)
    }

    @Test func grantCannotBeIssuedBeforeListenerIsReady() async {
        let result = await WebClientBridgeService().issueGrant(label: "browser")
        guard case let .failure(error) = result else {
            Issue.record("Expected stopped bridge to reject grant creation")
            return
        }
        #expect(error.code == "not_running")
    }

    @Test func managedPolicyBlocksBridgeStartupAndGrantCreation() async {
        let previous = MobileRemoteControlPolicy.overrideForTesting
        MobileRemoteControlPolicy.overrideForTesting = true
        defer { MobileRemoteControlPolicy.overrideForTesting = previous }

        let service = WebClientBridgeService()
        let start = await service.start()
        let grant = await service.issueGrant(label: "blocked")
        guard case let .failure(startError) = start,
              case let .failure(grantError) = grant else {
            Issue.record("Expected managed policy to block both operations")
            return
        }
        #expect(startError.code == "remote_control_disabled")
        #expect(grantError.code == "remote_control_disabled")
    }

    @Test func grantAdmissionGateRejectsAfterRevocation() {
        let gate = WebClientGrantAdmission()
        #expect(gate.withValidAdmission { true } == true)
        gate.invalidate()
        #expect(gate.withValidAdmission { true } == nil)
    }

    @Test func revokedGrantCannotReachTerminalMutationBoundary() async {
        let gate = WebClientGrantAdmission()
        gate.invalidate()
        let result = await MainActor.run {
            TerminalController.shared.webClientBridgeHandleRPC(
                MobileHostRPCRequest(
                    id: "revoked-input",
                    method: "terminal.input",
                    params: ["text": "must-not-run"],
                    auth: nil
                ),
                admission: gate,
                connectionID: UUID()
            )
        }
        guard case let .failure(error) = result else {
            Issue.record("Expected a revoked grant to stop before terminal input")
            return
        }
        #expect(error.code == "revoked")
    }

    @Test func revokedGrantCannotMutateSubscriptionState() async {
        let gate = WebClientGrantAdmission()
        let session = MobileHostConnection(
            id: UUID(),
            transport: GrantTestTransport(),
            usesWebEventEncoding: true,
            webGrantAdmission: gate,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        let streamID = "browser-events"
        let subscribed = await session.debugHandleSubscriptionRPCForTesting(
            MobileHostRPCRequest(
                id: "subscribe",
                method: "events.stream",
                params: ["stream_id": streamID, "topics": ["workspace.updated"]],
                auth: nil
            )
        )
        guard case .ok? = subscribed else {
            Issue.record("Expected the active browser grant to subscribe")
            await session.close(reason: "revoked subscription test failed")
            return
        }
        #expect(await session.isSubscribed(to: "workspace.updated"))

        gate.invalidate()
        let attach = await session.debugHandleSubscriptionRPCForTesting(
            MobileHostRPCRequest(
                id: "attach",
                method: "terminal.attach",
                params: [
                    "stream_id": "browser-terminal",
                    "surface_id": UUID().uuidString,
                ],
                auth: nil
            )
        )
        let cancel = await session.debugHandleSubscriptionRPCForTesting(
            MobileHostRPCRequest(
                id: "cancel",
                method: "events.cancel",
                params: ["stream_id": streamID],
                auth: nil
            )
        )
        guard case let .failure(attachError)? = attach,
              case let .failure(cancelError)? = cancel else {
            Issue.record("Expected revoked browser subscription mutations to fail")
            await session.close(reason: "revoked subscription test failed")
            return
        }
        #expect(attachError.code == "revoked")
        #expect(cancelError.code == "revoked")
        #expect(await session.isSubscribed(to: "workspace.updated"))
        await session.close(reason: "revoked subscription test complete")
    }

    @Test func mobileSubscriptionNormalizesAndValidatesSurfaceID() async {
        let surfaceID = UUID()
        let session = MobileHostConnection(
            id: UUID(),
            transport: GrantTestTransport(),
            usesWebEventEncoding: true,
            webGrantAdmission: WebClientGrantAdmission(),
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )

        let valid = await session.debugHandleSubscriptionRPCForTesting(
            MobileHostRPCRequest(
                id: "valid-surface",
                method: "mobile.events.subscribe",
                params: [
                    "stream_id": "surface-stream",
                    "topics": ["terminal.bytes"],
                    "surface_id": surfaceID.uuidString.lowercased(),
                ],
                auth: nil
            )
        )
        guard case .ok? = valid else {
            Issue.record("Expected a valid UUID surface subscription")
            await session.close(reason: "surface normalization test failed")
            return
        }
        #expect(
            await session.debugSubscriptionSurfaceIDForTesting(streamID: "surface-stream")
                == surfaceID.uuidString
        )

        let invalid = await session.debugHandleSubscriptionRPCForTesting(
            MobileHostRPCRequest(
                id: "invalid-surface",
                method: "mobile.events.subscribe",
                params: [
                    "stream_id": "invalid-stream",
                    "topics": ["terminal.bytes"],
                    "surface_id": "not-a-uuid",
                ],
                auth: nil
            )
        )
        guard case let .failure(error)? = invalid else {
            Issue.record("Expected an invalid UUID surface subscription to fail")
            await session.close(reason: "surface validation test failed")
            return
        }
        #expect(error.code == "invalid_params")
        await session.close(reason: "surface normalization test complete")
    }

    @Test(arguments: [
        "mobile.host.status",
        "mobile.workspace.list",
        "events.stream",
        "events.cancel",
        "terminal.attach",
        "terminal.replay",
        "terminal.viewport",
        "terminal.input",
    ])
    func browserGrantAllowsOnlyHandoffMethods(_ method: String) {
        #expect(TerminalController.webBridgeAllows(method: method))
    }

    @Test(arguments: [
        "workspace.list",
        "workspace.create",
        "file.read",
        "window.list",
        "terminal.paste",
        "mobile.attach_ticket.create",
        "mobile.chat.send",
        "web.bridge.status",
    ])
    func browserGrantRejectsBroaderControlMethods(_ method: String) {
        #expect(!TerminalController.webBridgeAllows(method: method))
    }

    @Test func browserRequestScopesViewportIdentityToServerConnection() {
        let connectionID = UUID()
        let viewport = TerminalController.webClientBridgeScopedRequest(
            MobileHostRPCRequest(
                id: "viewport",
                method: "terminal.replay",
                params: [
                    "client_id": "attacker-owned-client",
                    "viewport_columns": 120,
                    "viewport_rows": 40,
                ],
                auth: nil
            ),
            connectionID: connectionID
        )
        #expect(viewport.params["client_id"] as? String == "web:\(connectionID.uuidString)")
        #expect(viewport.params["viewport_columns"] as? Int == 120)
        #expect(viewport.params["viewport_rows"] as? Int == 40)

        let plainReplay = TerminalController.webClientBridgeScopedRequest(
            MobileHostRPCRequest(
                id: "plain",
                method: "terminal.replay",
                params: ["client_id": "attacker-owned-client"],
                auth: nil
            ),
            connectionID: connectionID
        )
        #expect(plainReplay.params["client_id"] == nil)

        let viewportReport = TerminalController.webClientBridgeScopedRequest(
            MobileHostRPCRequest(
                id: "report",
                method: "terminal.viewport",
                params: ["client_id": "attacker-owned-client", "clear": true],
                auth: nil
            ),
            connectionID: connectionID
        )
        #expect(viewportReport.params["client_id"] as? String == "web:\(connectionID.uuidString)")
    }

    @Test func browserGrantAuthorizationRunsForEveryRequest() async {
        let grantID = UUID()
        let request = MobileHostRPCRequest(
            id: "status",
            method: "mobile.host.status",
            params: [:],
            auth: nil
        )
        let result = await MobileHostService.connectionAuthorizationError(
            for: request,
            authorization: .webGrant(grantID),
            stackAuthorization: { _ in nil },
            webGrantAuthorization: { requestedGrantID, authorizedRequest in
                guard requestedGrantID == grantID,
                      authorizedRequest.method == request.method else {
                    return .failure(MobileHostRPCError(
                        code: "test_mismatch",
                        message: "Unexpected authorization input"
                    ))
                }
                return .failure(MobileHostRPCError(
                    code: "revoked",
                    message: "Browser grant has been revoked"
                ))
            }
        )
        guard case let .failure(error)? = result else {
            Issue.record("Expected web grant authorization failure")
            return
        }
        #expect(error.code == "revoked")
    }

    @Test func browserGrantAuthorizationStopsWhenManagedPolicyFlips() async {
        let previous = MobileRemoteControlPolicy.overrideForTesting
        MobileRemoteControlPolicy.overrideForTesting = true
        defer { MobileRemoteControlPolicy.overrideForTesting = previous }

        let result = await MobileHostService.connectionAuthorizationError(
            for: MobileHostRPCRequest(
                id: "input",
                method: "terminal.input",
                params: [:],
                auth: nil
            ),
            authorization: .webGrant(UUID()),
            stackAuthorization: { _ in nil },
            webGrantAuthorization: { _, _ in
                Issue.record("Web grant closure must not run while policy is disabled")
                return nil
            }
        )
        guard case let .failure(error)? = result else {
            Issue.record("Expected managed policy rejection")
            return
        }
        #expect(error.code == "remote_control_disabled")
    }

    @Test func browserGrantRejectsSubscriptionInterceptorBypass() async {
        let result = await MobileHostService.connectionAuthorizationError(
            for: MobileHostRPCRequest(
                id: "subscribe",
                method: "mobile.events.subscribe",
                params: ["topics": ["terminal.bytes"]],
                auth: nil
            ),
            authorization: .webGrant(UUID()),
            stackAuthorization: { _ in nil },
            webGrantAuthorization: { _, _ in
                .failure(MobileHostRPCError(
                    code: "authorization_ran",
                    message: "The grant closure should not run"
                ))
            }
        )
        guard case let .failure(error)? = result else {
            Issue.record("Expected browser allowlist rejection")
            return
        }
        #expect(error.code == "method_not_found")
    }

    @Test func terminalBytePayloadKeepsIOSNumericAndWebExactSequence() throws {
        let sequence = UInt64.max
        let payload = MobileTerminalByteTee.eventPayload(
            surfaceID: UUID(),
            sequence: sequence,
            data: Data("a".utf8)
        )
        #expect(payload["seq"] as? UInt64 == sequence)
        #expect(payload["seq_decimal"] == nil)
        let webPayload = try #require(MobileHostService.webTerminalBytePayload(payload))
        #expect(webPayload["seq"] as? String == String(sequence))
    }

    @Test func revokingOneGrantSelectsOnlyThatConnection() async {
        let registry = MobileHostConnectionRegistry()
        for connection in registry.removeAll() {
            await connection.close(reason: "web bridge test cleanup")
        }
        let firstGrant = UUID()
        let secondGrant = UUID()
        let firstTransport = GrantTestTransport()
        let secondTransport = GrantTestTransport()
        let firstID = UUID()
        let secondID = UUID()
        let firstAdmission = WebClientGrantAdmission()
        let secondAdmission = WebClientGrantAdmission()
        let first = MobileHostConnection(
            id: firstID,
            transport: firstTransport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { registry.remove(id: $0) }
        )
        let second = MobileHostConnection(
            id: secondID,
            transport: secondTransport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { registry.remove(id: $0) }
        )
        #expect(registry.insert(
            first,
            id: firstID,
            authorization: .webGrant(firstGrant),
            limit: 10,
            webGrantAdmission: firstAdmission
        ))
        #expect(registry.insert(
            second,
            id: secondID,
            authorization: .webGrant(secondGrant),
            limit: 10,
            webGrantAdmission: secondAdmission
        ))

        let selected = registry.removeWebGrantConnections(firstGrant)
        #expect(selected.count == 1)
        #expect(await selected.first?.connectionID == firstID)
        #expect(registry.connection(id: secondID) != nil)
        await selected.first?.close(reason: "grant revoked")
        #expect(await firstTransport.closed)
        #expect(!(await secondTransport.closed))
        for connection in registry.removeAll() {
            await connection.close(reason: "web bridge test cleanup")
        }
    }

    @Test func browserAndMobileConnectionsUseIndependentQuotasAndCounts() async {
        let registry = MobileHostConnectionRegistry()
        let makeConnection: (UUID) -> MobileHostConnection = { id in
            MobileHostConnection(
                id: id,
                transport: GrantTestTransport(),
                authorizeRequest: { _ in nil },
                onAuthorizedRequest: { _ in },
                handleRequest: { _ in .ok([:]) },
                onClose: { registry.remove(id: $0) }
            )
        }
        let firstWebID = UUID()
        let overflowWebID = UUID()
        let firstMobileID = UUID()
        let overflowMobileID = UUID()
        let firstWeb = makeConnection(firstWebID)
        let overflowWeb = makeConnection(overflowWebID)
        let firstMobile = makeConnection(firstMobileID)
        let overflowMobile = makeConnection(overflowMobileID)

        #expect(registry.insert(
            firstWeb,
            id: firstWebID,
            authorization: .webGrant(UUID()),
            limit: 1,
            webGrantAdmission: WebClientGrantAdmission()
        ))
        #expect(!registry.insert(
            overflowWeb,
            id: overflowWebID,
            authorization: .webGrant(UUID()),
            limit: 1,
            webGrantAdmission: WebClientGrantAdmission()
        ))
        #expect(registry.insert(
            firstMobile,
            id: firstMobileID,
            authorization: .stackBearer,
            limit: 1
        ))
        #expect(!registry.insert(
            overflowMobile,
            id: overflowMobileID,
            authorization: .stackBearer,
            limit: 1
        ))
        #expect(registry.count == 2)
        #expect(registry.mobileConnectionCount == 1)

        for connection in registry.removeAll() {
            await connection.close(reason: "independent quota test cleanup")
        }
        await overflowWeb.close(reason: "independent quota test cleanup")
        await overflowMobile.close(reason: "independent quota test cleanup")
    }

    @Test func webGrantRegistryInsertionRequiresAdmissionLease() async {
        let registry = MobileHostConnectionRegistry()
        let connectionID = UUID()
        let connection = MobileHostConnection(
            id: connectionID,
            transport: GrantTestTransport(),
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { registry.remove(id: $0) }
        )

        #expect(!registry.insert(
            connection,
            id: connectionID,
            authorization: .webGrant(UUID()),
            limit: 10
        ))
        #expect(registry.count == 0)
        await connection.close(reason: "missing web admission test complete")
    }
}

private actor GrantTestTransport: CmxByteTransport {
    private(set) var closed = false

    func connect() async throws {}
    func receive() async throws -> Data? { nil }
    func send(_: Data) async throws {}
    func close() async { closed = true }
}
