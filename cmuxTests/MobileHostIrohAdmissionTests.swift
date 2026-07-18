import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import CmuxTerminalBackend
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
    @Test func backendCompatibilityMaximumReplayFitsOneMobileRPCFrame() throws {
        let replay = Data(
            repeating: 0xA5,
            count: BackendTerminalCompatibilitySession.maximumReplayBytes
        )
        let response = MobileHostRPCEnvelope.encodeResponse(
            id: "replay-limit-proof",
            result: .ok([
                "snapshot_data_b64": replay.base64EncodedString(),
                "snapshot_format": "cmuxd.compatibility.vt",
                "terminal_fidelity": "noncanonical_byte_stream",
            ])
        )

        #expect(response.count <= MobileSyncFrameCodec.defaultMaximumFrameByteCount)
        _ = try MobileSyncFrameCodec.encodeFrame(response)
    }

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

    @Test func persistentStatusAdvertisesNoncanonicalByteStreamFidelity() throws {
        let payload = MobileHostService.publicStatusPayload(
            routes: [],
            profile: .backendCompatibility
        )
        let capabilities = try #require(payload["capabilities"] as? [String])

        #expect(payload["terminal_fidelity"] as? String == "noncanonical_byte_stream")
        #expect(capabilities.contains("terminal.byte_stream.compat.v1"))
        #expect(!capabilities.contains("terminal.render_grid.v1"))

        let embedded = MobileHostService.publicStatusPayload(
            routes: [],
            profile: .embeddedGhostty
        )
        let embeddedCapabilities = try #require(
            embedded["capabilities"] as? [String]
        )
        #expect(embedded["terminal_fidelity"] as? String == "render_grid")
        #expect(embeddedCapabilities.contains("terminal.render_grid.v1"))
        #expect(!embeddedCapabilities.contains("terminal.byte_stream.compat.v1"))
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

    @Test func persistentReplayHandoffsAreBoundedAndExpire() async throws {
        let factory = RecordingMobileCompatibilitySessionFactory(
            sequences: [10, 20, 30]
        )
        let sleeper = ManualMobileCompatibilitySleep()
        let plane = PersistentMobileTerminalDataPlane(
            sessionFactory: { surfaceID in
                await factory.make(surfaceID: surfaceID)
            },
            maximumPendingReplayCount: 2,
            pendingReplayTTL: .seconds(30),
            pendingSleep: { duration in
                try await sleeper.sleep(duration)
            }
        )

        _ = try await plane.replay(surfaceID: UUID())
        _ = try await plane.replay(surfaceID: UUID())
        _ = try await plane.replay(surfaceID: UUID())
        #expect(await plane.pendingReplayCountForTesting() == 2)
        let sessions = await factory.allSessions()
        #expect(sessions.count == 3)
        #expect(await sessions[0].closeCount() == 1)
        #expect(await sessions[1].closeCount() == 0)
        #expect(await sessions[2].closeCount() == 0)

        await waitForMobileCompatibilityWaiterCount(2, sleeper: sleeper)
        await sleeper.resumeAll()
        await waitForPendingReplayCount(0, plane: plane)
        #expect(await sessions[1].closeCount() == 1)
        #expect(await sessions[2].closeCount() == 1)
    }

    @Test func persistentReplayHandoffsEvictFIFOAtTheGlobalByteBudget() async throws {
        let factory = RecordingMobileCompatibilitySessionFactory(
            sequences: [6, 6, 6],
            replayByteCounts: [6, 6, 6]
        )
        let sleeper = ManualMobileCompatibilitySleep()
        let plane = PersistentMobileTerminalDataPlane(
            sessionFactory: { surfaceID in
                await factory.make(surfaceID: surfaceID)
            },
            maximumPendingReplayCount: 4,
            maximumPendingReplayBytes: 12,
            pendingReplayTTL: .seconds(30),
            pendingSleep: { duration in
                try await sleeper.sleep(duration)
            }
        )

        _ = try await plane.replay(surfaceID: UUID())
        _ = try await plane.replay(surfaceID: UUID())
        _ = try await plane.replay(surfaceID: UUID())

        let sessions = await factory.allSessions()
        #expect(await plane.pendingReplayCountForTesting() == 2)
        #expect(await plane.pendingReplayBytesForTesting() == 12)
        #expect(await sessions[0].closeCount() == 1)
        #expect(await sessions[1].closeCount() == 0)
        #expect(await sessions[2].closeCount() == 0)
        await plane.closePendingReplays()
    }

    @Test func persistentReplayHandoffUsesFIFOAndRejectsWrongCursorSynchronously() async throws {
        let surfaceID = UUID()
        let factory = RecordingMobileCompatibilitySessionFactory(
            sequences: [41, 41]
        )
        let sleeper = ManualMobileCompatibilitySleep()
        let plane = PersistentMobileTerminalDataPlane(
            sessionFactory: { surfaceID in
                await factory.make(surfaceID: surfaceID)
            },
            maximumPendingReplayCount: 4,
            pendingReplayTTL: .seconds(30),
            pendingSleep: { duration in
                try await sleeper.sleep(duration)
            }
        )

        _ = try await plane.replay(surfaceID: surfaceID)
        _ = try await plane.replay(surfaceID: surfaceID)
        let sessions = await factory.allSessions()
        #expect(sessions.count == 2)

        do {
            _ = try await plane.openLane(surfaceID: surfaceID, cursor: 99)
            Issue.record("wrong cursor unexpectedly returned a lane")
        } catch {
            #expect(error as? MobileTerminalDataPlaneError == .cursorGap)
        }
        #expect(await plane.pendingReplayCountForTesting() == 2)
        #expect(await sessions[0].eventClaimCount() == 0)
        #expect(await sessions[1].eventClaimCount() == 0)

        let firstLane = try await plane.openLane(surfaceID: surfaceID, cursor: 41)
        #expect(await sessions[0].eventClaimCount() == 1)
        #expect(await sessions[1].eventClaimCount() == 0)
        await firstLane.close()

        let secondLane = try await plane.openLane(surfaceID: surfaceID, cursor: 41)
        #expect(await sessions[1].eventClaimCount() == 1)
        await secondLane.close()
        #expect(await plane.pendingReplayCountForTesting() == 0)
    }

    @Test func persistentDirectLaneUsesStableVirtualCursorAcrossChangedSnapshots() async throws {
        let surfaceID = UUID()
        let factory = RecordingMobileCompatibilitySessionFactory(
            sequences: [6, 10],
            replayByteCounts: [300 * 1_024, 8]
        )
        let plane = PersistentMobileTerminalDataPlane(
            sessionFactory: { surfaceID in
                await factory.make(surfaceID: surfaceID)
            },
            maximumPendingReplayCount: 1,
            pendingReplayTTL: .seconds(30),
            pendingSleep: { _ in }
        )

        let lane = try await plane.openLane(surfaceID: surfaceID, cursor: nil)
        var iterator = try await lane.frames().makeAsyncIterator()
        let replay = try #require(try await iterator.next())
        let virtualCursor = UInt64(6) + PersistentMobileTerminalDataPlane.virtualReplayCursorOffset
        #expect(replay.kind == .replay)
        #expect(replay.data.count == 300 * 1_024)
        #expect(replay.sequence == virtualCursor - UInt64(300 * 1_024))
        #expect(replay.currentSequence == virtualCursor)

        let firstSession = try #require((await factory.allSessions()).first)
        await firstSession.emitOutput(startSequence: 6, data: Data("next".utf8))
        let output = try #require(try await iterator.next())
        #expect(output.kind == .chunk)
        #expect(output.sequence == virtualCursor)
        #expect(output.currentSequence == virtualCursor + 4)
        await lane.close()

        // The synthesized snapshot shrank from 300 KiB to 8 bytes. Reconnect
        // still resumes at daemon cursor 10 plus the fixed virtual offset.
        let resumed = try await plane.openLane(
            surfaceID: surfaceID,
            cursor: virtualCursor + 4
        )
        var resumedIterator = try await resumed.frames().makeAsyncIterator()
        let baseline = try #require(try await resumedIterator.next())
        #expect(baseline.kind == .replay)
        #expect(baseline.data.isEmpty)
        #expect(baseline.sequence == virtualCursor + 4)
        #expect(baseline.currentSequence == virtualCursor + 4)
        await resumed.close()
    }

    @Test func persistentRPCHandoffStaysOnCanonicalDaemonCursor() async throws {
        let surfaceID = UUID()
        let factory = RecordingMobileCompatibilitySessionFactory(
            sequences: [6],
            replayByteCounts: [8]
        )
        let plane = PersistentMobileTerminalDataPlane(
            sessionFactory: { surfaceID in
                await factory.make(surfaceID: surfaceID)
            },
            maximumPendingReplayCount: 1,
            pendingReplayTTL: .seconds(30),
            pendingSleep: { _ in }
        )

        let rpcReplay = try await plane.replay(surfaceID: surfaceID)
        #expect(rpcReplay.sequence == 6)
        #expect(rpcReplay.data.count == 8)
        let lane = try await plane.openLane(surfaceID: surfaceID, cursor: 6)
        var iterator = try await lane.frames().makeAsyncIterator()
        let baseline = try #require(try await iterator.next())
        #expect(baseline.kind == .replay)
        #expect(baseline.data.isEmpty)
        #expect(baseline.sequence == 6)
        #expect(baseline.currentSequence == 6)

        let session = try #require((await factory.allSessions()).first)
        await session.emitOutput(startSequence: 6, data: Data("x".utf8))
        let output = try #require(try await iterator.next())
        #expect(output.sequence == 6)
        #expect(output.currentSequence == 7)
        await lane.close()
    }

    @Test func persistentDirectLaneCursorOffsetOverflowFailsClosed() async throws {
        let offset = PersistentMobileTerminalDataPlane.virtualReplayCursorOffset
        let factory = RecordingMobileCompatibilitySessionFactory(
            sequences: [UInt64.max - offset + 1],
            replayByteCounts: [1]
        )
        let plane = PersistentMobileTerminalDataPlane(
            sessionFactory: { surfaceID in
                await factory.make(surfaceID: surfaceID)
            },
            maximumPendingReplayCount: 1,
            pendingReplayTTL: .seconds(30),
            pendingSleep: { _ in }
        )

        await #expect(throws: MobileTerminalDataPlaneError.cursorGap) {
            _ = try await plane.openLane(surfaceID: UUID(), cursor: nil)
        }
        let session = try #require((await factory.allSessions()).first)
        #expect(await session.eventClaimCount() == 0)
        #expect(await session.closeCount() == 1)
    }

    @Test func irohReplayEnvelopeSegmentationPreservesContiguousCoverage() throws {
        let payload = Data(repeating: 0x61, count: 300 * 1_024)
        let start: UInt64 = 900
        let frame = MobileTerminalDataPlaneFrame(
            kind: .replay,
            retainedBaseSequence: start,
            sequence: start,
            currentSequence: start + UInt64(payload.count),
            data: payload
        )

        let envelopes = try MobileHostIrohApplicationLaneRouter
            .terminalOutputEnvelopes(for: frame)
        #expect(envelopes.count == 2)
        #expect(envelopes[0].kind == .replay)
        #expect(envelopes[0].payload.count == CmxIrohTerminalOutputEnvelope.maximumPayloadByteCount)
        #expect(envelopes[0].sequence == start)
        #expect(envelopes[1].kind == .chunk)
        #expect(envelopes[1].sequence == envelopes[0].currentSequence)
        #expect(envelopes[1].currentSequence == frame.currentSequence)
        var reconstructed = Data()
        for envelope in envelopes { reconstructed.append(envelope.payload) }
        #expect(reconstructed == payload)

        let empty = try MobileHostIrohApplicationLaneRouter.terminalOutputEnvelopes(
            for: MobileTerminalDataPlaneFrame(
                kind: .replay,
                retainedBaseSequence: 42,
                sequence: 42,
                currentSequence: 42,
                data: Data()
            )
        )
        #expect(empty.count == 1)
        #expect(empty[0].kind == .replay)
        #expect(empty[0].payload.isEmpty)
    }

    @Test func consumedReplayCancelsExpiryAndLaneFramesHaveOneConsumer() async throws {
        let surfaceID = UUID()
        let factory = RecordingMobileCompatibilitySessionFactory(sequences: [7])
        let sleeper = ManualMobileCompatibilitySleep()
        let plane = PersistentMobileTerminalDataPlane(
            sessionFactory: { surfaceID in
                await factory.make(surfaceID: surfaceID)
            },
            maximumPendingReplayCount: 1,
            pendingReplayTTL: .seconds(30),
            pendingSleep: { duration in
                try await sleeper.sleep(duration)
            }
        )

        _ = try await plane.replay(surfaceID: surfaceID)
        await waitForMobileCompatibilityWaiterCount(1, sleeper: sleeper)
        let lane = try await plane.openLane(surfaceID: surfaceID, cursor: 7)
        await waitForMobileCompatibilityWaiterCount(0, sleeper: sleeper)

        _ = try await lane.frames()
        do {
            _ = try await lane.frames()
            Issue.record("a second frame consumer was accepted")
        } catch {
            #expect(error as? MobileTerminalDataPlaneError == .streamAlreadyClaimed)
        }
        let session = try #require((await factory.allSessions()).first)
        #expect(await session.closeCount() == 0)
        await lane.close()
        #expect(await session.closeCount() == 1)
    }

    @Test func persistentSlowPhoneOverflowsItsTwoSlotLaneAndClosesOnlyItsSession() async throws {
        #expect(PersistentMobileTerminalDataPlane.maximumBufferedEventsPerCompatibilityStage == 2)
        #expect(PersistentMobileTerminalDataPlane.maximumBufferedFramesPerLane == 2)

        let surfaceID = UUID()
        let factory = RecordingMobileCompatibilitySessionFactory(sequences: [7])
        let plane = PersistentMobileTerminalDataPlane(
            sessionFactory: { surfaceID in
                await factory.make(surfaceID: surfaceID)
            },
            maximumPendingReplayCount: 1,
            pendingReplayTTL: .seconds(30),
            pendingSleep: { _ in }
        )
        let lane = try await plane.openLane(surfaceID: surfaceID, cursor: nil)
        let frames = try await lane.frames()
        let session = try #require((await factory.allSessions()).first)

        await session.emitOutput(startSequence: 7, data: Data("a".utf8))
        await session.emitOutput(startSequence: 8, data: Data("b".utf8))
        await waitForMobileCompatibilityCloseCount(1, session: session)

        var iterator = frames.makeAsyncIterator()
        #expect(try await iterator.next()?.kind == .replay)
        #expect(try await iterator.next()?.data == Data("a".utf8))
        await #expect(throws: MobileTerminalDataPlaneError.streamOverflow) {
            _ = try await iterator.next()
        }
        #expect(await session.closeCount() == 1)
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

private actor RecordingMobileCompatibilitySessionFactory {
    private var sequences: [UInt64]
    private var replayByteCounts: [Int]
    private var sessions: [RecordingMobileCompatibilitySession] = []

    init(sequences: [UInt64], replayByteCounts: [Int] = []) {
        self.sequences = sequences
        self.replayByteCounts = replayByteCounts
    }

    func make(surfaceID: UUID) -> MobileBackendTerminalCompatibilityAttachment {
        let sequence = sequences.isEmpty ? 0 : sequences.removeFirst()
        let requestedReplayBytes = replayByteCounts.isEmpty ? 4 : replayByteCounts.removeFirst()
        let replayBytes = max(0, requestedReplayBytes)
        let snapshot = BackendTerminalCompatibilitySnapshot(
            surfaceID: SurfaceID(rawValue: surfaceID),
            runtimeEpoch: 1,
            generation: 1,
            sequence: sequence,
            columns: 80,
            rows: 24,
            replay: Data(repeating: 0x61, count: replayBytes)
        )
        let session = RecordingMobileCompatibilitySession(snapshot: snapshot)
        sessions.append(session)
        return MobileBackendTerminalCompatibilityAttachment(
            session: session,
            snapshot: snapshot
        )
    }

    func allSessions() -> [RecordingMobileCompatibilitySession] {
        sessions
    }
}

private actor RecordingMobileCompatibilitySession:
    MobileBackendTerminalCompatibilitySession {
    private let snapshot: BackendTerminalCompatibilitySnapshot
    private let stream: AsyncThrowingStream<BackendTerminalCompatibilityEvent, any Error>
    private let continuation:
        AsyncThrowingStream<BackendTerminalCompatibilityEvent, any Error>.Continuation
    private var eventClaims = 0
    private var closes = 0

    init(snapshot: BackendTerminalCompatibilitySnapshot) {
        let pair = AsyncThrowingStream<BackendTerminalCompatibilityEvent, any Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.snapshot = snapshot
        stream = pair.stream
        continuation = pair.continuation
        pair.continuation.yield(.snapshot(snapshot))
    }

    func events() throws -> AsyncThrowingStream<BackendTerminalCompatibilityEvent, any Error> {
        eventClaims += 1
        return stream
    }

    func sendInput(_: String) async throws {}

    func close() {
        guard closes == 0 else { return }
        closes += 1
        continuation.finish()
    }

    func emitOutput(startSequence: UInt64, data: Data) {
        continuation.yield(.output(BackendTerminalCompatibilityOutput(
            surfaceID: snapshot.surfaceID,
            runtimeEpoch: snapshot.runtimeEpoch,
            generation: snapshot.generation,
            startSequence: startSequence,
            nextSequence: startSequence + UInt64(data.count),
            data: data
        )))
    }

    func eventClaimCount() -> Int { eventClaims }
    func closeCount() -> Int { closes }
}

private actor ManualMobileCompatibilitySleep {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func sleep(_: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waiterCount() -> Int { waiters.count }

    func resumeAll() {
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    private func cancel(id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

@MainActor
private func waitForMobileCompatibilityWaiterCount(
    _ count: Int,
    sleeper: ManualMobileCompatibilitySleep
) async {
    for _ in 0 ..< 100 {
        if await sleeper.waiterCount() == count { return }
        await Task.yield()
    }
    Issue.record("timed out waiting for \(count) pending replay timers")
}

@MainActor
private func waitForPendingReplayCount(
    _ count: Int,
    plane: PersistentMobileTerminalDataPlane
) async {
    for _ in 0 ..< 100 {
        if await plane.pendingReplayCountForTesting() == count { return }
        await Task.yield()
    }
    Issue.record("timed out waiting for \(count) pending replay handoffs")
}

@MainActor
private func waitForMobileCompatibilityCloseCount(
    _ count: Int,
    session: RecordingMobileCompatibilitySession
) async {
    for _ in 0 ..< 100 {
        if await session.closeCount() == count { return }
        await Task.yield()
    }
    Issue.record("timed out waiting for \(count) closed compatibility sessions")
}
