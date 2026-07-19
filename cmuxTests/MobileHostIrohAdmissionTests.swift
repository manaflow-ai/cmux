import CMUXMobileCore
import CmuxAgentChat
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
}

@MainActor
@Suite(.serialized)
struct IrohTailscaleVersionSkewMacGateTests {
    @Test func testReleasedIOSWireFrameRemainsAcceptedByLegacyTCPAuthorization() async throws {
        let legacyPayload = Data(
            #"""
            {
              "id": "legacy-workspace-list",
              "method": "workspace.list",
              "params": {},
              "auth": { "stack_access_token": "legacy-stack-token" }
            }
            """#.utf8
        )
        let transport = LegacyIOSCompatibilityByteTransport()
        let stackAuthorization = LegacyStackAuthorizationRecorder()
        let session = MobileHostConnection(
            id: UUID(),
            transport: transport,
            firstFrameTimeoutNanoseconds: 0,
            idleTimeoutNanoseconds: 0,
            authorizeRequest: { request in
                await MobileHostService.connectionAuthorizationError(
                    for: request,
                    authorization: .legacyPrivateNetworkListener,
                    stackAuthorization: { decoded in
                        await stackAuthorization.record(decoded)
                        guard decoded.auth?.stackAccessToken == "legacy-stack-token" else {
                            return .failure(MobileHostRPCError(
                                code: "unauthorized",
                                message: "Legacy Stack bearer was not preserved"
                            ))
                        }
                        return nil
                    }
                )
            },
            onAuthorizedRequest: { _ in },
            handleRequest: { request in
                .ok([
                    "method": request.method,
                    "authorization": "stack_bearer",
                ])
            },
            onClose: { _ in }
        )
        let runTask = Task { await session.run() }
        await transport.enqueue(try MobileSyncFrameCodec.encodeFrame(legacyPayload))

        var responseBuffer = await transport.waitForSentBuffer()
        let responsePayloads = try MobileSyncFrameCodec.decodeFrames(from: &responseBuffer)
        let responsePayload = try #require(responsePayloads.first)
        let response = try #require(
            JSONSerialization.jsonObject(
                with: responsePayload
            ) as? [String: Any]
        )
        let result = try #require(response["result"] as? [String: Any])

        #expect(response["id"] as? String == "legacy-workspace-list")
        #expect(response["ok"] as? Bool == true)
        #expect(result["method"] as? String == "workspace.list")
        #expect(result["authorization"] as? String == "stack_bearer")
        #expect(await stackAuthorization.invocationCount() == 1)
        #expect(await stackAuthorization.lastToken() == "legacy-stack-token")

        await transport.finishReceiving()
        await runTask.value
    }

    @Test func testLegacyCompatibilityPolicyCannotBecomeIrohAdmission() {
        #expect(
            MobileHostConnectionAuthorizationContext.legacyPrivateNetworkListener
                == .stackBearer
        )
    }

    @Test func testLegacyCompatibilityRouteIsNumericTailscaleAndNeverLoopback() throws {
        let snapshot = MobileRouteResolver().routes(
            port: 58_465,
            tailscaleHosts: [
                "127.0.0.1",
                "work-mac.tailnet.ts.net",
                "100.71.210.41",
            ]
        )
        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }

        #expect(tailscaleRoutes.count == 1)
        guard case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint else {
            Issue.record("Expected a numeric Tailscale compatibility route")
            return
        }
        #expect(host == "100.71.210.41")
        #expect(port == 58_465)
        #expect(host != "127.0.0.1")
    }

    @Test func testStableExplicitSettingStartsIrohAndLegacyCompatibilityListener() throws {
        let suiteName = "IrohTailscaleVersionSkewMacGateTests.Current.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)

        let enabled = MobileHostService.isListeningEnabled(
            defaults: defaults,
            buildFlavor: .stable
        )
        let plan = MobileHostService.startupPlan(
            legacyListenerEnabled: enabled,
            legacyListenerRunning: false
        )

        #expect(plan.activatesIroh)
        #expect(plan.startsLegacyListener)
    }

    @Test func testStableHistoricalSettingStartsIrohAndLegacyCompatibilityListener() throws {
        let suiteName = "IrohTailscaleVersionSkewMacGateTests.Historical.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cmuxMobilePairingHostEnabled")

        let enabled = MobileHostService.isListeningEnabled(
            defaults: defaults,
            buildFlavor: .stable
        )
        let plan = MobileHostService.startupPlan(
            legacyListenerEnabled: enabled,
            legacyListenerRunning: false
        )

        #expect(plan.activatesIroh)
        #expect(plan.startsLegacyListener)
    }
}

@MainActor
extension MobileHostAuthorizationTests {

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
            supportsArtifactLane: true,
            stackStatus: { _ in .ok(["routes": []]) }
        )
        guard case let .ok(admittedPayload as [String: Any]) = admitted else {
            return #expect(Bool(false), "Admitted Iroh status must return an object")
        }
        #expect(admittedPayload["mac_device_id"] is String)
        let admittedCapabilities = try #require(admittedPayload["capabilities"] as? [String])
        #expect(admittedCapabilities.contains(MobileHostService.irohArtifactLaneCapability))

        let admittedWithoutHandler = await MobileHostService.connectionStatusResult(
            for: request,
            authorization: try irohAdmissionContext(),
            supportsArtifactLane: false,
            stackStatus: { _ in .ok(["routes": []]) }
        )
        guard case let .ok(unownedPayload as [String: Any]) = admittedWithoutHandler else {
            return #expect(Bool(false), "Admitted Iroh status must return an object")
        }
        let unownedCapabilities = try #require(unownedPayload["capabilities"] as? [String])
        #expect(!unownedCapabilities.contains(MobileHostService.irohArtifactLaneCapability))

        let tcp = await MobileHostService.connectionStatusResult(
            for: request,
            authorization: .stackBearer,
            stackStatus: { _ in
                .ok(MobileHostService.publicStatusPayload(routes: []))
            }
        )
        guard case let .ok(tcpPayload as [String: Any]) = tcp else {
            return #expect(Bool(false), "TCP status must return an object")
        }
        #expect(tcpPayload["mac_device_id"] == nil)
        let tcpCapabilities = try #require(tcpPayload["capabilities"] as? [String])
        #expect(!tcpCapabilities.contains(MobileHostService.irohArtifactLaneCapability))
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

    @Test func testIrohArtifactDescriptorFailuresPreserveFileAndCapacitySemantics() {
        #expect(
            MobileHostIrohArtifactTransferRegistry.Error.invalidFile.issueFailure
                == .fileNotFound
        )
        #expect(
            MobileHostIrohArtifactTransferRegistry.Error.unavailable.issueFailure
                == .unavailable
        )
        #expect(
            MobileHostIrohArtifactTransferRegistry.Error.capacityExceeded.issueFailure
                == .unavailable
        )
    }

    @Test func testIrohArtifactCapabilityIsOpaquePeerBoundAndSeriallyResumable() async throws {
        let fixture = try MobileHostIrohArtifactFixture(contents: Data("abcdef".utf8))
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MobileHostIrohArtifactTestClock(now: now)
        let resourceID = try CmxIrohResourceID(
            "artifact:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        )
        let registry = MobileHostIrohArtifactTransferRegistry(
            timeToLive: 60,
            now: { clock.now },
            resourceID: { resourceID }
        )
        let peer = try irohPeer(endpointCharacter: "a")
        let otherPeer = try irohPeer(endpointCharacter: "b")

        let descriptor = try await registry.issue(
            canonicalPath: fixture.path,
            peer: peer
        )

        #expect(descriptor.resourceID == resourceID.value)
        #expect(descriptor.totalSize == 6)
        #expect(descriptor.expiresAt == now.addingTimeInterval(60))
        #expect(!descriptor.resourceID.contains(fixture.path))
        await #expect(throws: MobileHostIrohArtifactTransferRegistry.Error.peerMismatch) {
            try await registry.claim(
                resourceID: resourceID,
                offset: 2,
                peer: otherPeer
            )
        }

        let lease = try await registry.claim(
            resourceID: resourceID,
            offset: 2,
            peer: peer
        )
        #expect(lease.offset == 2)
        #expect(lease.totalSize == 6)
        await #expect(throws: MobileHostIrohArtifactTransferRegistry.Error.alreadyInUse) {
            try await registry.claim(
                resourceID: resourceID,
                offset: 3,
                peer: peer
            )
        }
        await registry.release(lease)

        let resumed = try await registry.claim(
            resourceID: resourceID,
            offset: 4,
            peer: peer
        )
        #expect(resumed.offset == 4)
        await registry.release(resumed)

        let unknownResource = try CmxIrohResourceID(
            "artifact:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        )
        await #expect(throws: MobileHostIrohArtifactTransferRegistry.Error.unknownResource) {
            try await registry.claim(
                resourceID: unknownResource,
                offset: 0,
                peer: peer
            )
        }

        let separateSessionRegistry = MobileHostIrohArtifactTransferRegistry(
            timeToLive: 60,
            now: { clock.now },
            resourceID: { resourceID }
        )
        await #expect(throws: MobileHostIrohArtifactTransferRegistry.Error.unknownResource) {
            try await separateSessionRegistry.claim(
                resourceID: resourceID,
                offset: 0,
                peer: peer
            )
        }

        clock.advance(by: 61)
        await #expect(throws: MobileHostIrohArtifactTransferRegistry.Error.expired) {
            try await registry.claim(
                resourceID: resourceID,
                offset: 0,
                peer: peer
            )
        }
    }

    @Test func testIrohArtifactHandlerStreamsAuthorizedOffsetAtLowPriority() async throws {
        let fixture = try MobileHostIrohArtifactFixture(contents: Data("abcdef".utf8))
        defer { fixture.remove() }
        let resourceID = try CmxIrohResourceID(
            "artifact:abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
        )
        let registry = MobileHostIrohArtifactTransferRegistry(
            timeToLive: 60,
            now: Date.init,
            resourceID: { resourceID }
        )
        let peer = try irohPeer(endpointCharacter: "c")
        _ = try await registry.issue(canonicalPath: fixture.path, peer: peer)
        let send = RecordingMobileHostIrohArtifactSendStream()
        let receive = RecordingMobileHostIrohArtifactReceiveStream()
        let handler = MobileHostIrohArtifactLaneHandler(registry: registry)

        let didTakeOwnership = await handler.handleArtifactLane(
            resourceID: resourceID,
            offset: 2,
            stream: CmxIrohBidirectionalStream(
                receiveStream: receive,
                sendStream: send
            ),
            peer: peer
        )

        #expect(didTakeOwnership)
        #expect(await send.payload() == Data("cdef".utf8))
        #expect(await send.priorities() == [-10])
        #expect(await send.finishCount() == 1)
        #expect(await receive.stopCodes() == [0])
    }

    @Test func testIrohArtifactHandlerResetsIfFileChangesDuringTransfer() async throws {
        let fixture = try MobileHostIrohArtifactFixture(contents: Data("abcdef".utf8))
        defer { fixture.remove() }
        let resourceID = try CmxIrohResourceID(
            "artifact:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )
        let registry = MobileHostIrohArtifactTransferRegistry(
            timeToLive: 60,
            now: Date.init,
            resourceID: { resourceID }
        )
        let peer = try irohPeer(endpointCharacter: "d")
        _ = try await registry.issue(canonicalPath: fixture.path, peer: peer)
        let send = MutatingMobileHostIrohArtifactSendStream(path: fixture.path)
        let receive = RecordingMobileHostIrohArtifactReceiveStream()

        let didTakeOwnership = await MobileHostIrohArtifactLaneHandler(
            registry: registry
        ).handleArtifactLane(
            resourceID: resourceID,
            offset: 0,
            stream: CmxIrohBidirectionalStream(
                receiveStream: receive,
                sendStream: send
            ),
            peer: peer
        )

        #expect(didTakeOwnership)
        #expect(await send.finishCount() == 0)
        #expect(await send.resetCodes() == [6])
        #expect(await receive.stopCodes() == [0, 6])
    }

    @Test func testIrohApplicationLaneQuotasReserveArtifactCapacity() {
        #expect(MobileHostIrohApplicationLaneRouter.maximumConcurrentTerminalLaneCount == 4)
        #expect(MobileHostIrohApplicationLaneRouter.maximumConcurrentArtifactLaneCount == 1)
        #expect(MobileHostIrohApplicationLaneRouter.maximumConcurrentLaneCount == 5)

        var quota = MobileHostIrohApplicationLaneQuota()
        let terminalIDs = (0..<5).map { _ in UUID() }
        for id in terminalIDs.prefix(4) {
            let didReserve = quota.reserve(id, laneClass: .terminal)
            #expect(didReserve)
        }
        let didReserveFifthTerminal = quota.reserve(terminalIDs[4], laneClass: .terminal)
        #expect(!didReserveFifthTerminal)
        let artifactID = UUID()
        let didReserveArtifact = quota.reserve(artifactID, laneClass: .artifact)
        #expect(didReserveArtifact)
        let didReserveSecondArtifact = quota.reserve(UUID(), laneClass: .artifact)
        #expect(!didReserveSecondArtifact)
        #expect(quota.terminalCount == 4)
        #expect(quota.artifactCount == 1)

        quota.release(terminalIDs[0])
        let didReuseTerminalCredit = quota.reserve(terminalIDs[4], laneClass: .terminal)
        #expect(didReuseTerminalCredit)
        quota.release(artifactID)
        let didReuseArtifactCredit = quota.reserve(UUID(), laneClass: .artifact)
        #expect(didReuseArtifactCredit)
    }

    private func irohPeer(
        endpointCharacter: Character,
        generation: Int = 1
    ) throws -> CmxIrohAdmittedPeer {
        CmxIrohAdmittedPeer(peer: CmxIrohGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "test",
            platform: .ios,
            endpointID: try CmxIrohPeerIdentity(
                endpointID: String(repeating: String(endpointCharacter), count: 64)
            ),
            identityGeneration: generation
        ))
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

private struct MobileHostIrohArtifactFixture {
    let directory: URL
    let path: String

    init(contents: Data) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-iroh-artifact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("private-preview.bin")
        try contents.write(to: file, options: .atomic)
        self.directory = directory
        self.path = file.path
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class MobileHostIrohArtifactTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) {
        value = now
    }

    var now: Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            value = value.addingTimeInterval(interval)
        }
    }
}

private actor RecordingMobileHostIrohArtifactSendStream: CmxIrohSendStream {
    private var chunks: [Data] = []
    private var observedPriorities: [Int32] = []
    private var observedFinishCount = 0

    func send(_ data: Data) {
        chunks.append(data)
    }

    func finish() {
        observedFinishCount += 1
    }

    func reset(errorCode _: UInt64) {}

    func setPriority(_ priority: Int32) {
        observedPriorities.append(priority)
    }

    func payload() -> Data {
        chunks.reduce(into: Data()) { $0.append($1) }
    }

    func priorities() -> [Int32] { observedPriorities }
    func finishCount() -> Int { observedFinishCount }
}

private actor RecordingMobileHostIrohArtifactReceiveStream: CmxIrohReceiveStream {
    private var observedStopCodes: [UInt64] = []

    func receive(maximumByteCount _: Int) -> Data? { nil }

    func stop(errorCode: UInt64) {
        observedStopCodes.append(errorCode)
    }

    func stopCodes() -> [UInt64] { observedStopCodes }
}

private actor MutatingMobileHostIrohArtifactSendStream: CmxIrohSendStream {
    private let path: String
    private var didMutate = false
    private var observedFinishCount = 0
    private var observedResetCodes: [UInt64] = []

    init(path: String) {
        self.path = path
    }

    func send(_: Data) throws {
        guard !didMutate else { return }
        didMutate = true
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("changed-size".utf8))
    }

    func finish() {
        observedFinishCount += 1
    }

    func reset(errorCode: UInt64) {
        observedResetCodes.append(errorCode)
    }

    func setPriority(_: Int32) {}

    func finishCount() -> Int { observedFinishCount }
    func resetCodes() -> [UInt64] { observedResetCodes }
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

/// In-memory framed transport for the released-iOS compatibility contract.
/// It deliberately has no host, port, loopback socket, or Iroh endpoint, so the
/// test can only pass through the explicitly selected legacy authorization lane.
private actor LegacyIOSCompatibilityByteTransport: CmxByteTransport {
    private var receiveQueue: [Data?] = []
    private var receiveWaiter: CheckedContinuation<Data?, Never>?
    private var sentBuffer: Data?
    private var sentWaiters: [CheckedContinuation<Data, Never>] = []

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !receiveQueue.isEmpty {
            return receiveQueue.removeFirst()
        }
        return await withCheckedContinuation { receiveWaiter = $0 }
    }

    func send(_ data: Data) async throws {
        if sentBuffer == nil {
            sentBuffer = data
        } else {
            sentBuffer?.append(data)
        }
        guard let sentBuffer else { return }
        let waiters = sentWaiters
        sentWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: sentBuffer)
        }
    }

    func close() async {
        receiveWaiter?.resume(returning: nil)
        receiveWaiter = nil
    }

    func enqueue(_ data: Data) {
        if let receiveWaiter {
            self.receiveWaiter = nil
            receiveWaiter.resume(returning: data)
        } else {
            receiveQueue.append(data)
        }
    }

    func finishReceiving() {
        if let receiveWaiter {
            self.receiveWaiter = nil
            receiveWaiter.resume(returning: nil)
        } else {
            receiveQueue.append(nil)
        }
    }

    func waitForSentBuffer() async -> Data {
        if let sentBuffer {
            return sentBuffer
        }
        return await withCheckedContinuation { sentWaiters.append($0) }
    }
}

private actor LegacyStackAuthorizationRecorder {
    private var tokens: [String?] = []

    func record(_ request: MobileHostRPCRequest) {
        tokens.append(request.auth?.stackAccessToken)
    }

    func invocationCount() -> Int { tokens.count }
    func lastToken() -> String? { tokens.last ?? nil }
}
