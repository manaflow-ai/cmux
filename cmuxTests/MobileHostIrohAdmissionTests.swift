import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import Foundation
@preconcurrency import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension MobileHostAuthorizationTests {
    @Test func testPairingPayloadDefaultsCanDiscloseOnlyIrohIdentity() throws {
        let store = MobileAttachTicketStore()
        let endpointID = String(repeating: "a", count: 64)
        let iroh = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: endpointID),
                pathHints: []
            )
        )
        let tailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.7", port: 58465)
        )
        let ticket = try store.createTicket(
            workspaceID: "",
            terminalID: nil,
            routes: [iroh, tailscale],
            ttl: 3600,
            macUserEmail: "private@example.com",
            macUserID: "opaque-user-id"
        )

        let payload = try store.payload(
            for: ticket,
            routeDisclosureMode: .irohIdentityOnly
        )
        let attachURL = try #require(payload["attach_url"] as? String)
        let decoded = try CmxAttachTicketInput.decode(attachURL)

        #expect(decoded.routes.count == 1)
        #expect(decoded.routes.first?.kind == .iroh)
        guard case let .peer(identity, hints) = decoded.routes.first?.endpoint else {
            Issue.record("Expected identity-only Iroh route")
            return
        }
        #expect(identity.endpointID == endpointID)
        #expect(hints.isEmpty)
        #expect(!attachURL.contains("100.64.0.7"))
    }

    @Test func testLegacyPairingPayloadStillDecodesAsTailscale() throws {
        let store = MobileAttachTicketStore()
        let tailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.7", port: 58465)
        )
        let ticket = try store.createTicket(
            workspaceID: "",
            terminalID: nil,
            routes: [tailscale],
            ttl: 3600
        )

        let payload = try store.payload(
            for: ticket,
            routeDisclosureMode: .legacyPrivateNetworkCompatibility
        )
        let attachURL = try #require(payload["attach_url"] as? String)
        let decoded = try CmxAttachTicketInput.decode(attachURL)

        #expect(decoded.routes.count == 1)
        #expect(decoded.routes.first?.kind == .tailscale)
        #expect(decoded.routes.first?.endpoint == .hostPort(host: "100.64.0.7", port: 58465))
    }

    @Test func testLegacyPairingPayloadDropsIrohFromMixedHostRoutes() throws {
        let store = MobileAttachTicketStore()
        let iroh = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                pathHints: []
            ),
            priority: 0
        )
        let tailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.7", port: 58465),
            priority: 10
        )
        let ticket = try store.createTicket(
            workspaceID: "",
            terminalID: nil,
            routes: [iroh, tailscale],
            ttl: 3600,
            macUserEmail: "private@example.com",
            macUserID: "opaque-user-id"
        )

        let payload = try store.payload(
            for: ticket,
            routeDisclosureMode: .legacyPrivateNetworkCompatibility
        )
        let attachURL = try #require(payload["attach_url"] as? String)
        let decoded = try CmxAttachTicketInput.decode(attachURL)

        #expect(!CmxPairingQRCode().isPairingCodeURLString(attachURL))
        #expect(decoded.routes == [tailscale])
        #expect(decoded.authToken == nil)
        let sourceExpiry = try #require(ticket.expiresAt)
        let legacyExpiry = try #require(decoded.expiresAt)
        #expect(legacyExpiry > sourceExpiry.addingTimeInterval(365 * 24 * 60 * 60))
        #expect(!attachURL.contains(String(repeating: "a", count: 64)))

        let components = try #require(URLComponents(string: attachURL))
        let encoded = try #require(
            components.queryItems?.first(where: { $0.name == "payload" })?.value
        )
        let legacyData = try #require(Self.decodeBase64URL(encoded))
        let legacyObject = try #require(
            JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        )
        #expect(legacyObject["version"] as? Int == CmxAttachTicket.currentVersion)
        #expect(legacyObject["expiresAt"] != nil)
        #expect(legacyObject["auth_token"] == nil)
        #expect(legacyObject["macUserEmail"] == nil)
        #expect(legacyObject["macUserID"] as? String == "opaque-user-id")
        #expect((legacyObject["routes"] as? [[String: Any]])?.count == 1)
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }
        return Data(base64Encoded: base64)
    }

    @Test func testBindingPublicationDoesNotWaitForPersistence() async {
        let queue = MobileHostIrohPersistenceQueue()
        let gate = MobileHostIrohPersistenceGate()
        var published = false

        queue.publishAndEnqueue(
            publish: { published = true },
            persist: { await gate.wait() }
        )
        await gate.waitUntilStarted()

        #expect(published)
        await queue.cancel()
        await gate.resume()
    }

    #if DEBUG
    @Test func testMacIrohVerificationModeUsesTheSharedDefaultsContract() throws {
        let suiteName = "MobileHostIrohAdmissionTests.transport-mode.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MobileHostIrohRuntime.debugTransportVerificationMode(defaults: defaults) == .automatic)
        defaults.set(
            CmxIrohTransportVerificationMode.relayOnly.rawValue,
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        #expect(MobileHostIrohRuntime.debugTransportVerificationMode(defaults: defaults) == .relayOnly)
        defaults.set(
            CmxIrohTransportVerificationMode.directOnly.rawValue,
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        #expect(MobileHostIrohRuntime.debugTransportVerificationMode(defaults: defaults) == .directOnly)
    }
    #endif

    @Test func testIrohAdmissionReplacesPerRequestStackAuthorization() async throws {
        let recorder = MobileHostAuthorizationInvocationRecorder()
        let request = MobileHostRPCRequest(
            id: "workspace-list",
            method: "workspace.list",
            params: [:],
            auth: nil
        )
        let admitted = await MobileHostService.connectionAuthorizationError(
            for: request,
            authorization: try irohAdmissionContext(),
            stackAuthorization: { _ in
                await recorder.record()
                return .failure(MobileHostRPCError(
                    code: "unauthorized",
                    message: "Stack should not run"
                ))
            }
        )
        #expect(admitted == nil)
        #expect(await recorder.count() == 0)

        let tcp = await MobileHostService.connectionAuthorizationError(
            for: request,
            authorization: .stackBearer,
            stackAuthorization: { _ in
                await recorder.record()
                return .failure(MobileHostRPCError(
                    code: "unauthorized",
                    message: "Missing Stack bearer"
                ))
            }
        )
        guard case let .failure(error) = tcp else {
            return #expect(Bool(false), "Tokenless TCP must retain Stack authorization")
        }
        #expect(error.code == "unauthorized")
        #expect(await recorder.count() == 1)
    }
    @Test func testIrohAdmittedStatusIncludesIdentityWhileTCPPublicStatusDoesNot() async throws {
        let request = MobileHostRPCRequest(
            id: "host-status",
            method: "mobile.host.status",
            params: [:],
            auth: nil
        )
        let admitted = await MobileHostService.connectionStatusResult(
            for: request,
            authorization: try irohAdmissionContext(),
            stackStatus: { _ in .ok(["routes": []]) }
        )
        guard case let .ok(admittedPayload as [String: Any]) = admitted else {
            return #expect(Bool(false), "Admitted Iroh status must return an object")
        }
        #expect(admittedPayload["mac_device_id"] is String)

        let tcp = await MobileHostService.connectionStatusResult(
            for: request,
            authorization: .stackBearer,
            stackStatus: { _ in .ok(["routes": []]) }
        )
        guard case let .ok(tcpPayload as [String: Any]) = tcp else {
            return #expect(Bool(false), "TCP status must return an object")
        }
        #expect(tcpPayload["mac_device_id"] == nil)
    }

    @Test func testIrohTerminalLaneInputFramingSurvivesQUICChunkBoundaries() throws {
        var buffer = Data([0, 0])
        #expect(try MobileHostIrohApplicationLaneRouter.decodeTerminalInputFrames(from: &buffer).isEmpty)
        buffer.append(contentsOf: [0, 2, 0xc3])
        #expect(try MobileHostIrohApplicationLaneRouter.decodeTerminalInputFrames(from: &buffer).isEmpty)
        buffer.append(0xa9)
        #expect(
            try MobileHostIrohApplicationLaneRouter.decodeTerminalInputFrames(from: &buffer)
                == ["é"]
        )
        #expect(buffer.isEmpty)
    }

    @Test func testIrohDefaultArtifactLaneHandlerRejectsUntilConsumerRegisters() async throws {
        let stream = CmxIrohBidirectionalStream(
            receiveStream: ImmediateMobileHostIrohReceiveStream(),
            sendStream: BlockingMobileHostIrohSendStream()
        )
        let handler = MobileHostIrohRejectingArtifactLaneHandler()
        let resourceID = try CmxIrohResourceID("artifact:preview")
        let peer = CmxIrohAdmittedPeer(peer: CmxIrohGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "test",
            platform: .ios,
            endpointID: try CmxIrohPeerIdentity(
                endpointID: String(repeating: "a", count: 64)
            ),
            identityGeneration: 1
        ))
        #expect(
            await handler.handleArtifactLane(
                resourceID: resourceID,
                offset: 0,
                stream: stream,
                peer: peer
            ) == false
        )
    }

    func irohAdmissionContext() throws -> MobileHostConnectionAuthorizationContext {
        let endpointID = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let peer = CmxIrohGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "ios-test",
            platform: .ios,
            endpointID: endpointID,
            identityGeneration: 1
        )
        return .irohAdmission(CmxIrohAdmittedPeer(peer: peer))
    }
}

private actor MobileHostIrohPersistenceGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
