import CMUXMobileCore
import CmuxAgentChat
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
            CmxIrohPathPreference.relayOnly.rawValue,
            forKey: CmxIrohPathPreference.defaultsKey
        )
        #expect(MobileHostIrohRuntime.debugTransportVerificationMode(defaults: defaults) == .relayOnly)
        defaults.set(
            CmxIrohTransportVerificationMode.directOnly.rawValue,
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        #expect(MobileHostIrohRuntime.debugTransportVerificationMode(defaults: defaults) == .directOnly)
        defaults.removeObject(forKey: CmxIrohTransportVerificationMode.debugDefaultsKey)
        defaults.set(
            CmxIrohPathPreference.automatic.rawValue,
            forKey: CmxIrohPathPreference.defaultsKey
        )
        defaults.set(true, forKey: MobileHostIrohRuntime.debugRelayOnlyDefaultsKey)
        #expect(MobileHostIrohRuntime.debugTransportVerificationMode(defaults: defaults) == .relayOnly)
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
            sessionFactory: { surfaceID, clientUUID in
                await factory.make(surfaceID: surfaceID, clientUUID: clientUUID)
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
            sessionFactory: { surfaceID, clientUUID in
                await factory.make(surfaceID: surfaceID, clientUUID: clientUUID)
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
            sessionFactory: { surfaceID, clientUUID in
                await factory.make(surfaceID: surfaceID, clientUUID: clientUUID)
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
            sessionFactory: { surfaceID, clientUUID in
                await factory.make(surfaceID: surfaceID, clientUUID: clientUUID)
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
            sessionFactory: { surfaceID, clientUUID in
                await factory.make(surfaceID: surfaceID, clientUUID: clientUUID)
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

    @Test func persistentPhoneLanesKeepUniqueStableClientUUIDsAcrossHandoffAndReconnect()
        async throws {
        let surfaceID = UUID()
        let firstClient = UUID()
        let secondClient = UUID()
        let thirdClient = UUID()
        let clientUUIDs = LockedMobileClientUUIDSequence([
            firstClient,
            secondClient,
            thirdClient,
        ])
        let factory = RecordingMobileCompatibilitySessionFactory(
            sequences: [10, 20, 30]
        )
        let plane = PersistentMobileTerminalDataPlane(
            sessionFactory: { surfaceID, clientUUID in
                await factory.make(surfaceID: surfaceID, clientUUID: clientUUID)
            },
            maximumPendingReplayCount: 2,
            pendingReplayTTL: .seconds(30),
            pendingSleep: { _ in },
            clientUUIDProvider: { clientUUIDs.next() }
        )

        let replay = try await plane.replay(surfaceID: surfaceID)
        let handedOff = try await plane.openLane(
            surfaceID: surfaceID,
            cursor: replay.sequence
        )
        #expect(await factory.allClientUUIDs() == [firstClient])
        #expect(await plane.liveClientUUIDsForTesting() == [firstClient])
        await handedOff.close()
        #expect(await plane.liveClientUUIDsForTesting().isEmpty)

        let reconnected = try await plane.openLane(surfaceID: surfaceID, cursor: nil)
        let secondPhone = try await plane.openLane(surfaceID: surfaceID, cursor: nil)
        #expect(
            await factory.allClientUUIDs()
                == [firstClient, secondClient, thirdClient]
        )
        #expect(
            await plane.liveClientUUIDsForTesting()
                == Set([secondClient, thirdClient])
        )
        await reconnected.close()
        await secondPhone.close()
        #expect(await plane.liveClientUUIDsForTesting().isEmpty)
    }

    @Test func persistentPhoneLaneAllocationSkipsALiveClientUUIDCollision() async throws {
        let surfaceID = UUID()
        let firstClient = UUID()
        let secondClient = UUID()
        let clientUUIDs = LockedMobileClientUUIDSequence([
            firstClient,
            firstClient,
            secondClient,
        ])
        let factory = RecordingMobileCompatibilitySessionFactory(sequences: [1, 2])
        let plane = PersistentMobileTerminalDataPlane(
            sessionFactory: { surfaceID, clientUUID in
                await factory.make(surfaceID: surfaceID, clientUUID: clientUUID)
            },
            maximumPendingReplayCount: 1,
            pendingReplayTTL: .seconds(30),
            pendingSleep: { _ in },
            clientUUIDProvider: { clientUUIDs.next() }
        )

        let first = try await plane.openLane(surfaceID: surfaceID, cursor: nil)
        let second = try await plane.openLane(surfaceID: surfaceID, cursor: nil)
        #expect(await factory.allClientUUIDs() == [firstClient, secondClient])
        #expect(clientUUIDs.callCount() == 3)
        await first.close()
        await second.close()
    }

    @Test func staleDoubleCloseCannotReleaseAReusedPhoneClientUUID() async throws {
        let surfaceID = UUID()
        let reusedClient = UUID()
        let clientUUIDs = LockedMobileClientUUIDSequence([
            reusedClient,
            reusedClient,
        ])
        let factory = RecordingMobileCompatibilitySessionFactory(sequences: [1, 2])
        let plane = PersistentMobileTerminalDataPlane(
            sessionFactory: { surfaceID, clientUUID in
                await factory.make(surfaceID: surfaceID, clientUUID: clientUUID)
            },
            maximumPendingReplayCount: 1,
            pendingReplayTTL: .seconds(30),
            pendingSleep: { _ in },
            clientUUIDProvider: { clientUUIDs.next() }
        )

        let oldLane = try await plane.openLane(surfaceID: surfaceID, cursor: nil)
        await oldLane.close()
        #expect(await plane.liveClientUUIDsForTesting().isEmpty)

        let newLane = try await plane.openLane(surfaceID: surfaceID, cursor: nil)
        #expect(await plane.liveClientUUIDsForTesting() == [reusedClient])
        await oldLane.close()
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(await plane.liveClientUUIDsForTesting() == [reusedClient])

        await newLane.close()
        #expect(await plane.liveClientUUIDsForTesting().isEmpty)
    }

    @Test func persistentDirectLaneCursorOffsetOverflowFailsClosed() async throws {
        let offset = PersistentMobileTerminalDataPlane.virtualReplayCursorOffset
        let factory = RecordingMobileCompatibilitySessionFactory(
            sequences: [UInt64.max - offset + 1],
            replayByteCounts: [1]
        )
        let plane = PersistentMobileTerminalDataPlane(
            sessionFactory: { surfaceID, clientUUID in
                await factory.make(surfaceID: surfaceID, clientUUID: clientUUID)
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
            sessionFactory: { surfaceID, clientUUID in
                await factory.make(surfaceID: surfaceID, clientUUID: clientUUID)
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
            sessionFactory: { surfaceID, clientUUID in
                await factory.make(surfaceID: surfaceID, clientUUID: clientUUID)
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

private actor RecordingMobileCompatibilitySessionFactory {
    private var sequences: [UInt64]
    private var replayByteCounts: [Int]
    private var sessions: [RecordingMobileCompatibilitySession] = []
    private var clientUUIDs: [UUID] = []

    init(sequences: [UInt64], replayByteCounts: [Int] = []) {
        self.sequences = sequences
        self.replayByteCounts = replayByteCounts
    }

    func make(
        surfaceID: UUID,
        clientUUID: UUID
    ) -> MobileBackendTerminalCompatibilityAttachment {
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
        clientUUIDs.append(clientUUID)
        return MobileBackendTerminalCompatibilityAttachment(
            clientUUID: clientUUID,
            session: session,
            snapshot: snapshot
        )
    }

    func allSessions() -> [RecordingMobileCompatibilitySession] {
        sessions
    }

    func allClientUUIDs() -> [UUID] {
        clientUUIDs
    }
}

// The synchronous Sendable UUID-provider seam cannot await an actor; the lock
// protects only this test helper's bounded sequence and call counter.
private final class LockedMobileClientUUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]
    private var calls = 0

    init(_ values: [UUID]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if values.count > 1 { return values.removeFirst() }
        return values[0]
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
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
