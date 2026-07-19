import AuthenticationServices
import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileTransport
import CryptoKit
import Foundation
import Testing
@testable import cmuxFeature

@MainActor
@Suite
struct MobileIrohRuntimeCompositionTests {
    @Test
    @MainActor
    func foregroundRevalidatesAuthBeforeConnectionReadinessCompletes() async throws {
        let fixture = try await MobileIrohSignOutFixture.make()
        let baseline = await fixture.authClient.observedCurrentUserCallCount()

        fixture.composition.didBecomeActive()
        await fixture.composition.prepareForConnection()

        #expect(await fixture.authClient.observedCurrentUserCallCount() > baseline)
    }

    @Test
    func bakedIrohBrokerOriginDoesNotReplaceTheGeneralAPIOrigin() {
        #expect(MobileIrohRuntimeComposition.resolvedBrokerBaseURL(
            apiBaseURL: "http://localhost:9450",
            infoDictionary: [
                "CMUXIrohBrokerBaseURL": "https://cmux-staging.vercel.app",
            ]
        )?.absoluteString == "https://cmux-staging.vercel.app")
        #expect(MobileIrohRuntimeComposition.resolvedBrokerBaseURL(
            apiBaseURL: "https://cmux.com",
            infoDictionary: ["CMUXIrohBrokerBaseURL": "  "]
        )?.absoluteString == "https://cmux.com")

        #expect(MobileIrohRuntimeComposition.resolvedBrokerBaseURL(
            apiBaseURL: "http://localhost:9450",
            infoDictionary: ["CMUXDevTag": "lane-a"]
        )?.absoluteString == "https://cmux-staging.vercel.app")
        #expect(MobileIrohRuntimeComposition.resolvedBrokerBaseURL(
            apiBaseURL: "http://localhost:9450",
            infoDictionary: [
                "CMUXDevTag": "lane-a",
                "CMUXAuthEnvironment": "production",
            ]
        )?.absoluteString == "https://cmux.com")
        #expect(MobileIrohRuntimeComposition.resolvedBrokerBaseURL(
            apiBaseURL: "https://cmux.com",
            infoDictionary: ["CMUXIrohBrokerBaseURL": ":// malformed"]
        ) == nil)
        #expect(MobileIrohRuntimeComposition.resolvedBrokerBaseURL(
            apiBaseURL: "https://cmux.com",
            infoDictionary: ["CMUXIrohBrokerBaseURL": "http://localhost:3000"],
            allowsLoopback: false
        ) == nil)
    }

    @Test
    func initialAuthenticationAndFirstConnectionDoNotReplayTheSameAuthState() async throws {
        let fixture = try await MobileIrohSignOutFixture.make()

        #expect(await fixture.endpointFactory.bindCount() == 1)
    }

    #if DEBUG
    @Test
    func debugTransportModePersistsAndRebindsWithoutRotatingIdentity() async throws {
        let fixture = try await MobileIrohSignOutFixture.make()
        let initialBindCount = await fixture.endpointFactory.bindCount()
        #expect(fixture.endpointFactoryModes.modes == [.automatic])

        try await fixture.composition.setIrohDebugTransportVerificationMode(.directOnly)

        #expect(
            fixture.debugDefaults.string(
                forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
            ) == CmxIrohTransportVerificationMode.directOnly.rawValue
        )
        #expect(await fixture.endpointFactory.bindCount() == initialBindCount + 1)
        #expect(fixture.endpointFactoryModes.modes == [.automatic, .directOnly])
        #expect(
            await fixture.composition.irohSettingsSnapshot()
                .debugTransportVerificationMode == .directOnly
        )
        try await fixture.expectOriginalRepositoriesRemain()

        try await fixture.composition.setIrohDebugTransportVerificationMode(.directOnly)

        #expect(await fixture.endpointFactory.bindCount() == initialBindCount + 1)
        #expect(fixture.endpointFactoryModes.modes == [.automatic, .directOnly])

        try await fixture.composition.setIrohDebugTransportVerificationMode(.relayOnly)

        #expect(await fixture.endpointFactory.bindCount() == initialBindCount + 2)
        #expect(fixture.endpointFactoryModes.modes == [.automatic, .directOnly, .relayOnly])
        #expect(
            await fixture.composition.irohSettingsSnapshot()
                .debugTransportVerificationMode == .relayOnly
        )
        try await fixture.expectOriginalRepositoriesRemain()
    }
    #endif

    @Test
    func connectionReadinessIgnoresSupersededLifecycleCompletion() async {
        let readiness = MobileIrohConnectionReadinessSignal()
        readiness.begin(revision: 1)
        readiness.begin(revision: 2)

        #expect(readiness.complete(revision: 1) == false)
        #expect(readiness.isPending)
        #expect(readiness.complete(revision: 2))
        #expect(readiness.isPending == false)

        await readiness.wait()
    }

    @Test
    func discoveryRefreshDiagnosticPreservesTypedFailureCategory() throws {
        let offline = try #require(
            MobileIrohRuntimeComposition.discoveryRefreshFailureEvent(
                for: .failed(.offline)
            )
        )
        #expect(offline.code == .discoveryFailed)
        #expect(offline.a == DiagnosticTransportKind.iroh.rawValue)
        #expect(offline.b == DiagnosticFailureKind.offline.rawValue)
        #expect(offline.surface == nil)
        #expect(offline.c == nil)

        let unavailable = try #require(
            MobileIrohRuntimeComposition.discoveryRefreshFailureEvent(
                for: .failed(.policyUnavailable)
            )
        )
        #expect(unavailable.b == DiagnosticFailureKind.policyUnavailable.rawValue)
        #expect(
            MobileIrohRuntimeComposition.discoveryRefreshFailureEvent(
                for: .refreshed
            ) == nil
        )
    }

    @Test
    func discoveryCatalogRetainsFortyConcurrentDevelopmentBindings() async throws {
        let bindings = (0..<40).map { index in
            mobileIrohBinding(
                bindingID: String(format: "00000000-0000-4000-8000-%012d", index),
                deviceID: String(format: "10000000-0000-4000-8000-%012d", index),
                appInstanceID: String(format: "20000000-0000-4000-8000-%012d", index),
                endpointID: String(format: "%064x", index + 1),
                platform: "mac",
                pairingEnabled: true
            )
        }
        let discovery = try mobileIrohDiscovery(bindings: bindings)
        let catalog = MobileIrohRouteCatalog()
        await catalog.activate(scope: 1)
        await catalog.replace(with: discovery, scope: 1)

        for index in 0..<40 {
            let deviceID = String(format: "10000000-0000-4000-8000-%012d", index)
            #expect(await catalog.routes(
                forKnownMacDeviceID: deviceID,
                instanceTag: "test"
            ).count == 1)
        }
    }

    @Test
    func discoveryCatalogOrdersFractionalAndWholeSecondTimestamps() async throws {
        let deviceID = "30000000-0000-4000-8000-000000000101"
        let olderBindingID = "30000000-0000-4000-8000-000000000102"
        let newerBindingID = "30000000-0000-4000-8000-000000000103"
        let discovery = try mobileIrohDiscovery(bindings: [
            mobileIrohBinding(
                bindingID: olderBindingID,
                deviceID: deviceID,
                appInstanceID: "30000000-0000-4000-8000-000000000104",
                endpointID: String(repeating: "a", count: 64),
                platform: "mac",
                pairingEnabled: true,
                lastSeenAt: "2027-07-10T12:00:00.500Z"
            ),
            mobileIrohBinding(
                bindingID: newerBindingID,
                deviceID: deviceID,
                appInstanceID: "30000000-0000-4000-8000-000000000105",
                endpointID: String(repeating: "b", count: 64),
                platform: "mac",
                pairingEnabled: true,
                lastSeenAt: "2027-07-10T12:00:01Z"
            ),
        ])
        let catalog = MobileIrohRouteCatalog()
        await catalog.activate(scope: 2)
        await catalog.replace(with: discovery, scope: 2)

        #expect(await catalog.routes(
            forKnownMacDeviceID: deviceID,
            instanceTag: "test"
        ).map(\.id) == [
            "iroh-personal-\(newerBindingID)",
            "iroh-personal-\(olderBindingID)",
        ])
    }

    @Test
    func zeroTouchDiscoveryRejectsAmbiguousEndpointAndDeviceTagBindings() async throws {
        let duplicateDeviceID = "30000000-0000-4000-8000-000000000001"
        let discovery = try mobileIrohDiscovery(bindings: [
            mobileIrohBinding(
                bindingID: "30000000-0000-4000-8000-000000000002",
                deviceID: "30000000-0000-4000-8000-000000000003",
                appInstanceID: "30000000-0000-4000-8000-000000000004",
                endpointID: String(repeating: "a", count: 64),
                platform: "mac",
                pairingEnabled: true
            ),
            mobileIrohBinding(
                bindingID: "30000000-0000-4000-8000-000000000005",
                deviceID: "30000000-0000-4000-8000-000000000006",
                appInstanceID: "30000000-0000-4000-8000-000000000007",
                endpointID: String(repeating: "a", count: 64),
                platform: "mac",
                pairingEnabled: true
            ),
            mobileIrohBinding(
                bindingID: "30000000-0000-4000-8000-000000000008",
                deviceID: duplicateDeviceID,
                appInstanceID: "30000000-0000-4000-8000-000000000009",
                endpointID: String(repeating: "b", count: 64),
                platform: "mac",
                pairingEnabled: true
            ),
            mobileIrohBinding(
                bindingID: "30000000-0000-4000-8000-000000000010",
                deviceID: duplicateDeviceID,
                appInstanceID: "30000000-0000-4000-8000-000000000011",
                endpointID: String(repeating: "c", count: 64),
                platform: "mac",
                pairingEnabled: true
            ),
            mobileIrohBinding(
                bindingID: "30000000-0000-4000-8000-000000000012",
                deviceID: "30000000-0000-4000-8000-000000000013",
                appInstanceID: "30000000-0000-4000-8000-000000000014",
                endpointID: String(repeating: "d", count: 64),
                platform: "mac",
                pairingEnabled: true
            ),
        ])
        let catalog = MobileIrohRouteCatalog()
        await catalog.activate(scope: 3)
        await catalog.replace(with: discovery, scope: 3)

        let candidates = await catalog.liveMacCandidates(preferredTag: "test")
        #expect(candidates.count == 1)
        #expect(candidates.first?.deviceID == "30000000-0000-4000-8000-000000000013")
    }

    @Test
    func zeroTouchDiscoveryIgnoresUnreachableStaleBindingForSameDeviceTag() async throws {
        let now = Date()
        let observedAt = now.addingTimeInterval(-30).timeIntervalSinceReferenceDate
        let expiresAt = now.addingTimeInterval(30 * 60).timeIntervalSinceReferenceDate
        let currentRelayPath: [String: Any] = [
            "kind": "relay_url",
            "value": "https://use1-1.relay.lawrence.cmux.iroh.link/",
            "source": "native",
            "privacy_scope": "public_internet",
            "observed_at": observedAt,
            "expires_at": expiresAt,
        ]
        let deviceID = "30000000-0000-4000-8000-000000000021"
        let reachableBindingID = "30000000-0000-4000-8000-000000000022"
        let discovery = try mobileIrohDiscovery(bindings: [
            mobileIrohBinding(
                bindingID: "30000000-0000-4000-8000-000000000023",
                deviceID: deviceID,
                appInstanceID: "30000000-0000-4000-8000-000000000024",
                endpointID: String(repeating: "e", count: 64),
                platform: "mac",
                pairingEnabled: true,
                lastSeenAt: "2027-07-10T11:00:00.000Z"
            ),
            mobileIrohBinding(
                bindingID: reachableBindingID,
                deviceID: deviceID,
                appInstanceID: "30000000-0000-4000-8000-000000000025",
                endpointID: String(repeating: "f", count: 64),
                platform: "mac",
                pairingEnabled: true,
                lastSeenAt: "2027-07-10T12:00:00.000Z",
                pathHints: [currentRelayPath]
            ),
        ])
        let catalog = MobileIrohRouteCatalog()
        await catalog.activate(scope: 31)
        await catalog.replace(with: discovery, scope: 31)

        let candidates = await catalog.liveMacCandidates(preferredTag: "test")
        #expect(candidates.count == 1)
        #expect(candidates.first?.routes.map(\.id) == [
            "iroh-personal-\(reachableBindingID)",
        ])

        let ambiguousDiscovery = try mobileIrohDiscovery(bindings: [
            mobileIrohBinding(
                bindingID: "30000000-0000-4000-8000-000000000023",
                deviceID: deviceID,
                appInstanceID: "30000000-0000-4000-8000-000000000024",
                endpointID: String(repeating: "e", count: 64),
                platform: "mac",
                pairingEnabled: true,
                lastSeenAt: "2027-07-10T11:00:00.000Z",
                pathHints: [currentRelayPath]
            ),
            mobileIrohBinding(
                bindingID: reachableBindingID,
                deviceID: deviceID,
                appInstanceID: "30000000-0000-4000-8000-000000000025",
                endpointID: String(repeating: "f", count: 64),
                platform: "mac",
                pairingEnabled: true,
                lastSeenAt: "2027-07-10T12:00:00.000Z",
                pathHints: [currentRelayPath]
            ),
        ])
        await catalog.replace(with: ambiguousDiscovery, scope: 31)
        #expect(await catalog.liveMacCandidates(preferredTag: "test").isEmpty)
    }

    @Test
    func taggedDevelopmentDiscoveryCannotCrossIntoAnotherAgentLane() async throws {
        let discovery = try mobileIrohDiscovery(bindings: [
            mobileIrohBinding(
                bindingID: "31000000-0000-4000-8000-000000000001",
                deviceID: "31000000-0000-4000-8000-000000000002",
                appInstanceID: "31000000-0000-4000-8000-000000000003",
                endpointID: String(repeating: "a", count: 64),
                platform: "mac",
                pairingEnabled: true,
                tag: "lane-a"
            ),
            mobileIrohBinding(
                bindingID: "31000000-0000-4000-8000-000000000004",
                deviceID: "31000000-0000-4000-8000-000000000005",
                appInstanceID: "31000000-0000-4000-8000-000000000006",
                endpointID: String(repeating: "b", count: 64),
                platform: "mac",
                pairingEnabled: true,
                tag: "lane-b"
            ),
            mobileIrohBinding(
                bindingID: "31000000-0000-4000-8000-000000000007",
                deviceID: "31000000-0000-4000-8000-000000000008",
                appInstanceID: "31000000-0000-4000-8000-000000000009",
                endpointID: String(repeating: "c", count: 64),
                platform: "mac",
                pairingEnabled: true,
                tag: "default"
            ),
        ])
        let catalog = MobileIrohRouteCatalog()
        await catalog.activate(scope: 4)
        await catalog.replace(with: discovery, scope: 4)

        let isolated = await catalog.liveMacCandidates(
            preferredTag: "lane-a",
            compatibleWith: .development(expectedInstanceTag: "lane-a")
        )
        #expect(isolated.map(\.instanceTag) == ["lane-a"])

        let official = await catalog.liveMacCandidates(
            preferredTag: "lane-a",
            compatibleWith: .official
        )
        #expect(official.map(\.instanceTag) == ["default"])
    }

    @Test
    func relayPolicyRefreshesBeforeExpiryAndDeactivatesOnlyAtExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        let expiresAt = now.addingTimeInterval(300)
        let retryAt = now.addingTimeInterval(15)
        let retryAfterExpiry = expiresAt.addingTimeInterval(600)

        #expect(MobileIrohRuntimeComposition.relayPolicyRefreshAttemptDate(
            policyExpiresAt: expiresAt,
            retryAt: nil,
            now: now
        ) == now.addingTimeInterval(240))
        #expect(MobileIrohRuntimeComposition.relayPolicyRefreshAttemptDate(
            policyExpiresAt: expiresAt,
            retryAt: retryAt,
            now: now
        ) == retryAt)
        #expect(MobileIrohRuntimeComposition.relayPolicyRefreshAttemptDate(
            policyExpiresAt: expiresAt,
            retryAt: retryAfterExpiry,
            now: now
        ) == expiresAt)
        #expect(MobileIrohRuntimeComposition.relayPolicyRefreshAttemptDate(
            policyExpiresAt: nil,
            retryAt: nil,
            now: now
        ) == now.addingTimeInterval(30))
        #expect(!MobileIrohRuntimeComposition.shouldDeactivateRelayPolicy(
            policyExpiresAt: expiresAt,
            now: expiresAt.addingTimeInterval(-0.001)
        ))
        #expect(MobileIrohRuntimeComposition.shouldDeactivateRelayPolicy(
            policyExpiresAt: expiresAt,
            now: expiresAt
        ))
        #expect(!MobileIrohRuntimeComposition.shouldDeactivateRelayPolicy(
            policyExpiresAt: nil,
            now: expiresAt
        ))
    }

    @Test
    func terminalLaneFramesUTF8InputAndOwnsBothStreamHalves() async throws {
        let outputEnvelope = try CmxIrohTerminalOutputEnvelope(
            kind: .replay,
            retainedBaseSequence: 10,
            sequence: 10,
            currentSequence: 16,
            payload: Data("output".utf8)
        )
        let encodedOutput = CmxIrohTerminalOutputEnvelopeCodec().encode(outputEnvelope)
        let receive = MobileIrohTerminalLaneReceiveStream(chunks: [
            Data(encodedOutput.prefix(5)),
            Data(encodedOutput.dropFirst(5)),
        ])
        let send = MobileIrohTerminalLaneSendStream()
        let lane = MobileIrohTerminalLane(
            stream: CmxIrohBidirectionalStream(
                receiveStream: receive,
                sendStream: send
            )
        )

        try await lane.sendInput("é")
        try await lane.finishInput()
        #expect(try await lane.receiveOutput() == MobileTerminalLaneOutputFrame(
            kind: .replay,
            retainedBaseSequence: 10,
            sequence: 10,
            currentSequence: 16,
            bytes: Data("output".utf8)
        ))

        let frames = await send.frames()
        #expect(frames == [Data([0, 0, 0, 2, 0xc3, 0xa9])])
        #expect(await send.finishCount() == 1)

        await lane.close()
        #expect(await send.resetCodes() == [0])
        #expect(await receive.stopCodes() == [0])
        await #expect(throws: MobileIrohTerminalLaneError.closed) {
            try await lane.sendInput("x")
        }
    }

    @Test
    func terminalLaneRejectsUnboundedInputBeforeWriting() async throws {
        let receive = MobileIrohTerminalLaneReceiveStream(chunks: [])
        let send = MobileIrohTerminalLaneSendStream()
        let lane = MobileIrohTerminalLane(
            stream: CmxIrohBidirectionalStream(
                receiveStream: receive,
                sendStream: send
            )
        )

        await #expect(throws: MobileIrohTerminalLaneError.inputTooLarge) {
            try await lane.sendInput(
                String(repeating: "x", count: MobileIrohTerminalLane.maximumInputByteCount + 1)
            )
        }
        #expect(await send.frames().isEmpty)
    }

    @Test
    func compositionUsesInjectedGenerationAwareNetworkSnapshot() async throws {
        let suiteName = "MobileIrohRuntimeCompositionTests.snapshot"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let installState = CmxIrohUserDefaultsInstallStateStore(defaults: defaults)
        let snapshotRecorder = MobileIrohSnapshotRecorder()
        let composition = MobileIrohRuntimeComposition(
            appInstances: CmxIrohAppInstanceRepository(store: installState),
            identities: CmxIrohIdentityRepository(
                secureStore: CmxIrohKeychainIdentityStore(service: "\(suiteName).identity"),
                installState: installState
            ),
            brokerCredentials: CmxIrohBrokerCredentialRepository(
                secureStore: CmxIrohKeychainCredentialStore(service: "\(suiteName).relay"),
                installState: installState
            ),
            pendingRevocations: CmxIrohPendingRevocationOutbox(
                secureStore: CmxIrohKeychainCredentialStore(
                    service: "\(suiteName).pending-revocations"
                )
            ),
            endpointFactory: MobileIrohNeverEndpointFactory(),
            brokerFactory: { _ in throw TestCompositionError.unavailable },
            deviceID: { "123e4567-e89b-42d3-a456-426614174040" },
            tag: "test",
            now: { Date(timeIntervalSince1970: 1_000) },
            networkPathSnapshot: {
                await snapshotRecorder.snapshot()
            }
        )

        let snapshot = try await composition.currentNetworkPathSnapshot()

        #expect(snapshot.generation == 42)
        #expect(snapshot.activeNetworkProfiles.isEmpty)
        #expect(await snapshotRecorder.callCount() == 1)
    }

    @Test
    func pathStateAdvancesGenerationWhileProfilesRemainFailClosed() async {
        let state = MobileIrohNetworkPathState(
            networkInterfaces: MobileIrohInterfaceProvider([])
        )
        let initial = await state.snapshot()

        await state.pathDidChange()
        let changed = await state.snapshot()

        #expect(initial.generation == 1)
        #expect(changed.generation == 2)
        #expect(changed.activeNetworkProfiles.isEmpty)
    }

    @Test
    func lanProfileAuthorizationIsBoundToPathGenerationAndRevocation() async throws {
        let state = MobileIrohNetworkPathState(
            networkInterfaces: MobileIrohInterfaceProvider([])
        )
        let profile = try CmxIrohNetworkProfileKey(
            source: .lan,
            profileID: String(repeating: "a", count: 64)
        )

        #expect(await state.authorizeLANProfile(
            profile,
            generation: 2,
            interfaceIndex: 4
        ) == false)
        #expect(await state.authorizeLANProfile(
            profile,
            generation: 1,
            interfaceIndex: 0
        ) == false)
        #expect(await state.authorizeLANProfile(
            profile,
            generation: 1,
            interfaceIndex: 4
        ))
        #expect(await state.snapshot().activeNetworkProfiles == [profile])

        await state.revokeLANProfile(profile, generation: 2)
        #expect(await state.snapshot().activeNetworkProfiles == [profile])

        await state.revokeLANProfile(profile, generation: 1)
        #expect(await state.snapshot().activeNetworkProfiles.isEmpty)

        #expect(await state.authorizeLANProfile(
            profile,
            generation: 1,
            interfaceIndex: 4
        ))
        await state.pathDidChange()
        let changed = await state.snapshot()
        #expect(changed.generation == 2)
        #expect(changed.activeNetworkProfiles.isEmpty)
        #expect(await state.authorizeLANProfile(
            profile,
            generation: 1,
            interfaceIndex: 4
        ) == false)
    }

    @Test
    func pathStateAuthorizesTailscaleProfileOnlyWhileTailnetIsActive() async throws {
        let provider = MobileIrohInterfaceProvider([
            NetworkInterfaceAddress(
                interfaceName: "utun5",
                address: "100.99.1.2"
            ),
        ])
        let state = MobileIrohNetworkPathState(networkInterfaces: provider)
        let profile = CmxIrohNetworkProfileKey.activeTailscaleTunnel

        #expect(await state.snapshot().activeNetworkProfiles == [profile])

        provider.set([
            NetworkInterfaceAddress(
                interfaceName: "en0",
                address: "192.168.1.2"
            ),
        ])
        #expect(await state.snapshot().activeNetworkProfiles.isEmpty)
    }

    @Test
    func verifiedPersonalMacDiscoverySurfacesAZeroTouchCandidate() async throws {
        let macDeviceID = "123e4567-e89b-42d3-a456-426614174041"
        let discovery = try mobileIrohDiscovery(
            bindings: [
                mobileIrohBinding(
                    bindingID: "123e4567-e89b-42d3-a456-426614174042",
                    deviceID: macDeviceID,
                    appInstanceID: "123e4567-e89b-42d3-a456-426614174043",
                    endpointID: String(repeating: "a", count: 64),
                    platform: "mac",
                    pairingEnabled: true
                ),
                mobileIrohBinding(
                    bindingID: "123e4567-e89b-42d3-a456-426614174044",
                    deviceID: "123e4567-e89b-42d3-a456-426614174045",
                    appInstanceID: "123e4567-e89b-42d3-a456-426614174046",
                    endpointID: String(repeating: "b", count: 64),
                    platform: "ios",
                    pairingEnabled: false
                ),
            ]
        )
        let catalog = MobileIrohRouteCatalog()
        await catalog.activate(scope: 7)
        await catalog.replace(with: discovery, scope: 7)
        let base = MobileIrohBaseRegistry(
            routes: [try CmxAttachRoute(
                id: "tailscale",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.64.0.10", port: 50906),
                priority: 10
            )]
        )
        let registry = PersonalIrohDeviceRegistryDecorator(
            base: base,
            catalog: catalog,
            knownRoutes: { requestedDeviceID, instanceTag in
                guard requestedDeviceID.lowercased() == macDeviceID else { return nil }
                return await base.freshRoutes(
                    forMacDeviceID: requestedDeviceID,
                    instanceTag: instanceTag
                )
            }
        )

        let routes = try #require(await registry.freshRoutes(
            forMacDeviceID: macDeviceID,
            instanceTag: "test"
        ))

        #expect(routes.map(\.kind) == [.iroh, .tailscale])
        guard case let .peer(identity, hints) = routes[0].endpoint else {
            Issue.record("Expected an Iroh peer route")
            return
        }
        #expect(identity.endpointID == String(repeating: "a", count: 64))
        let tailscaleHint = try #require(hints.first)
        #expect(tailscaleHint.kind == .directAddress)
        #expect(tailscaleHint.value == "100.64.0.10:50906")
        #expect(tailscaleHint.source == .tailscale)
        #expect(tailscaleHint.privacyScope == .privateNetwork)
        #expect(tailscaleHint.use == .fallbackOnly)
        #expect(tailscaleHint.networkProfile?.source == .tailscale)
        #expect(tailscaleHint.isUsable(at: Date()))
        let tailscaleProfile = try #require(tailscaleHint.networkProfile)
        let dialPlan = try #require(routes[0].endpoint.irohDialPlan(
            at: Date(),
            managedRelayURLs: [],
            activeNetworkProfiles: [tailscaleProfile]
        ))
        #expect(dialPlan.privateFallbackPaths == [tailscaleHint])
        #expect(await registry.freshRoutes(
            forMacDeviceID: "123e4567-e89b-42d3-a456-426614174099",
            instanceTag: "test"
        )?.map(\.kind) == [.tailscale])
        #expect(await registry.freshRoutes(
            forMacDeviceID: macDeviceID,
            instanceTag: "other-build"
        )?.map(\.kind) == [.tailscale])
        switch await registry.listDevices() {
        case let .ok(devices):
            let device = try #require(devices.first)
            #expect(devices.count == 1)
            #expect(device.deviceId == macDeviceID)
            #expect(device.platform == "mac")
            #expect(device.instances.count == 1)
            #expect(device.instances[0].tag == "test")
            #expect(device.instances[0].routes.map(\.kind) == [.iroh])
        case .authRejected, .transientFailure:
            Issue.record("Verified live Iroh discovery did not create a device-list candidate")
        }
    }

    @Test
    func staleAccountDiscoveryCannotRepopulateOrClearCurrentCatalog() async throws {
        let macDeviceID = "123e4567-e89b-42d3-a456-426614174051"
        let discovery = try mobileIrohDiscovery(bindings: [
            mobileIrohBinding(
                bindingID: "123e4567-e89b-42d3-a456-426614174052",
                deviceID: macDeviceID,
                appInstanceID: "123e4567-e89b-42d3-a456-426614174053",
                endpointID: String(repeating: "c", count: 64),
                platform: "mac",
                pairingEnabled: true
            ),
        ])
        let catalog = MobileIrohRouteCatalog()

        await catalog.activate(scope: 1)
        await catalog.activate(scope: 2)
        await catalog.replace(with: discovery, scope: 1)
        #expect(await catalog.routes(
            forKnownMacDeviceID: macDeviceID,
            instanceTag: "test"
        ).isEmpty)

        await catalog.replace(with: discovery, scope: 2)
        await catalog.deactivate(scope: 1)
        #expect(await catalog.routes(
            forKnownMacDeviceID: macDeviceID,
            instanceTag: "test"
        ).count == 1)

        await catalog.deactivate(scope: 2)
        #expect(await catalog.routes(
            forKnownMacDeviceID: macDeviceID,
            instanceTag: "test"
        ).isEmpty)
    }

    @Test
    func cachedBindingsRestoreRoutesOnlyForAnAlreadyKnownMac() async throws {
        let macDeviceID = "123e4567-e89b-42d3-a456-426614174061"
        let discovery = try mobileIrohDiscovery(bindings: [
            mobileIrohBinding(
                bindingID: "123e4567-e89b-42d3-a456-426614174062",
                deviceID: macDeviceID,
                appInstanceID: "123e4567-e89b-42d3-a456-426614174063",
                endpointID: String(repeating: "d", count: 64),
                platform: "mac",
                pairingEnabled: true
            ),
        ])
        let catalog = MobileIrohRouteCatalog()
        await catalog.activate(scope: 9)
        await catalog.replace(with: discovery, scope: 9)
        #expect(await catalog.liveMacCandidates(preferredTag: "test").count == 1)
        await catalog.replaceCachedBindings(discovery.bindings, scope: 9)
        #expect(await catalog.liveMacCandidates(preferredTag: "test").isEmpty)
        let registry = PersonalIrohDeviceRegistryDecorator(
            base: nil,
            catalog: catalog,
            knownRoutes: { requestedDeviceID, instanceTag in
                requestedDeviceID == macDeviceID ? [] : nil
            }
        )

        #expect(
            await registry.freshRoutes(
                forMacDeviceID: macDeviceID,
                instanceTag: "test"
            )?.map(\.kind)
                == [.iroh]
        )
        #expect(
            await registry.freshRoutes(
                forMacDeviceID: "123e4567-e89b-42d3-a456-426614174099",
                instanceTag: "test"
            ) == nil
        )
        switch await registry.listDevices() {
        case .transientFailure: break
        case .authRejected, .ok: Issue.record("Cached Iroh routes created a device-list row")
        }
    }

    @Test
    func failedFallbackPersistenceQuarantinesRepositoriesAndBlocksAccountRotation() async throws {
        let fixture = try await MobileIrohSignOutFixture.make()
        await fixture.outboxStore.setWriteMode(.fail)

        let preparation = await fixture.composition.prepareSignOut()

        #expect(preparation.pendingRevocation == fixture.pendingRevocation)
        #expect(preparation.wasPersisted == false)
        try await fixture.expectOriginalRepositoriesRemain()

        await fixture.auth.signOut(onSignedOut: { _, _ in })
        await fixture.authClient.setUser(fixture.otherUser)
        try await fixture.auth.signInWithPassword(email: "b@example.com", password: "pw")
        await #expect(throws: CmxIrohClientRuntimeError.self) {
            _ = try await fixture.composition.transport(for: fixture.request)
        }

        #expect(
            await fixture.endpointFactory.bindCount() == fixture.initialBindCount
        )
        #expect(await fixture.broker.revokedBindingIDs().isEmpty)
        try await fixture.expectOriginalRepositoriesRemain()
    }

    @Test
    func capturedTokenHookRetriesExactPreparationBeforeWipingQuarantine() async throws {
        let fixture = try await MobileIrohSignOutFixture.make()
        await fixture.outboxStore.setWriteMode(.fail)
        let preparation = await fixture.composition.prepareSignOut()
        #expect(preparation.wasPersisted == false)
        try await fixture.expectOriginalRepositoriesRemain()
        await fixture.outboxStore.setWriteMode(.normal)

        // Auth still reports the signing-out account between preparation and
        // its local clear. That state must not look like a later sign-in.
        await #expect(throws: CmxIrohClientRuntimeError.self) {
            _ = try await fixture.composition.transport(for: fixture.request)
        }
        #expect(await fixture.broker.revokedBindingIDs().isEmpty)
        #expect(
            await fixture.endpointFactory.bindCount() == fixture.initialBindCount
        )
        try await fixture.expectOriginalRepositoriesRemain()

        await fixture.auth.signOut { accessToken, refreshToken in
            await fixture.composition.revokeAfterSignOut(
                preparation,
                accessToken: accessToken,
                refreshToken: refreshToken
            )
        }

        #expect(await fixture.broker.revokedBindingIDs() == [fixture.bindingID])
        #expect(
            try await fixture.outbox.pending(accountID: fixture.accountID).isEmpty
        )
        try await fixture.expectRepositoriesWereWiped()
    }

    @Test
    func laterSameAccountAuthenticationRetriesQuarantineBeforeActivation() async throws {
        let fixture = try await MobileIrohSignOutFixture.make()
        await fixture.outboxStore.setWriteMode(.fail)
        let preparation = await fixture.composition.prepareSignOut()
        #expect(preparation.wasPersisted == false)
        await fixture.auth.signOut(onSignedOut: { _, _ in })

        await fixture.authClient.setUser(fixture.otherUser)
        try await fixture.auth.signInWithPassword(email: "b@example.com", password: "pw")
        await #expect(throws: CmxIrohClientRuntimeError.self) {
            _ = try await fixture.composition.transport(for: fixture.request)
        }
        #expect(
            await fixture.endpointFactory.bindCount() == fixture.initialBindCount
        )
        #expect(await fixture.broker.revokedBindingIDs().isEmpty)
        try await fixture.expectOriginalRepositoriesRemain()

        await fixture.auth.signOut(onSignedOut: { _, _ in })
        await fixture.outboxStore.setWriteMode(.normal)
        await fixture.authClient.setUser(fixture.user)
        try await fixture.auth.signInWithPassword(email: "a@example.com", password: "pw")
        await #expect(throws: CmxIrohClientRuntimeError.self) {
            _ = try await fixture.composition.transport(for: fixture.request)
        }

        #expect(await fixture.broker.revokedBindingIDs() == [fixture.bindingID])
        #expect(
            await fixture.endpointFactory.bindCount()
                == fixture.initialBindCount + 1
        )
        #expect(
            try await fixture.outbox.pending(accountID: fixture.accountID).isEmpty
        )
        #expect(
            try await fixture.appInstances.appInstanceID(
                accountID: fixture.accountID,
                tag: fixture.tag
            ) != fixture.appInstanceID
        )
    }

    @Test
    func concurrentSignOutCannotOvertakeSuspendedPersistence() async throws {
        let fixture = try await MobileIrohSignOutFixture.make()
        await fixture.outboxStore.setWriteMode(.suspendThenFail)
        let first = Task { await fixture.composition.prepareSignOut() }
        await fixture.outboxStore.waitUntilWriteStarts()
        let secondCompletion = MobileIrohCompletionProbe()
        let second = Task {
            let preparation = await fixture.composition.prepareSignOut()
            await secondCompletion.finish()
            return preparation
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await secondCompletion.isFinished() == false)
        #expect(await fixture.outboxStore.writeCount() == 1)
        try await fixture.expectOriginalRepositoriesRemain()

        await fixture.outboxStore.resumeSuspendedWrite()
        let firstPreparation = await first.value
        let secondPreparation = await second.value

        #expect(firstPreparation == secondPreparation)
        #expect(firstPreparation.pendingRevocation == fixture.pendingRevocation)
        #expect(firstPreparation.wasPersisted == false)
        #expect(await fixture.outboxStore.writeCount() == 1)
        try await fixture.expectOriginalRepositoriesRemain()
    }
}

private actor MobileIrohTerminalLaneSendStream: CmxIrohSendStream {
    private var sentFrames: [Data] = []
    private var finishes = 0
    private var resets: [UInt64] = []

    func send(_ data: Data) {
        sentFrames.append(data)
    }

    func finish() {
        finishes += 1
    }

    func reset(errorCode: UInt64) {
        resets.append(errorCode)
    }

    func setPriority(_: Int32) {}

    func frames() -> [Data] { sentFrames }
    func finishCount() -> Int { finishes }
    func resetCodes() -> [UInt64] { resets }
}

private actor MobileIrohTerminalLaneReceiveStream: CmxIrohReceiveStream {
    private var chunks: [Data]
    private var stops: [UInt64] = []

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func receive(maximumByteCount: Int) -> Data? {
        guard !chunks.isEmpty else { return nil }
        let first = chunks.removeFirst()
        guard first.count > maximumByteCount else { return first }
        chunks.insert(Data(first.dropFirst(maximumByteCount)), at: 0)
        return Data(first.prefix(maximumByteCount))
    }

    func stop(errorCode: UInt64) {
        stops.append(errorCode)
    }

    func stopCodes() -> [UInt64] { stops }
}

private enum TestCompositionError: Error {
    case unavailable
}

private actor MobileIrohNeverEndpointFactory: CmxIrohEndpointFactory {
    func bind(
        configuration _: CmxIrohEndpointConfiguration
    ) throws -> any CmxIrohEndpoint {
        throw TestCompositionError.unavailable
    }
}

private actor MobileIrohSnapshotRecorder {
    private var calls = 0

    func snapshot() -> CmxIrohNetworkPathSnapshot {
        calls += 1
        return CmxIrohNetworkPathSnapshot(
            generation: 42,
            activeNetworkProfiles: []
        )
    }

    func callCount() -> Int { calls }
}

private actor MobileIrohBaseRegistry: DeviceRegistryRefreshing {
    let routes: [CmxAttachRoute]

    init(routes: [CmxAttachRoute]) {
        self.routes = routes
    }

    func freshRoutes(
        forMacDeviceID _: String,
        instanceTag _: String?
    ) -> [CmxAttachRoute]? { routes }
    func listDevices() -> DeviceRegistryListOutcome { .ok([]) }
}

private final class MobileIrohInterfaceProvider:
    NetworkInterfaceAddressProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var interfaces: [NetworkInterfaceAddress]?

    init(_ interfaces: [NetworkInterfaceAddress]?) {
        self.interfaces = interfaces
    }

    func set(_ interfaces: [NetworkInterfaceAddress]?) {
        lock.lock()
        self.interfaces = interfaces
        lock.unlock()
    }

    func currentInterfaceAddresses() -> [NetworkInterfaceAddress]? {
        lock.lock()
        defer { lock.unlock() }
        return interfaces
    }
}

@MainActor
private struct MobileIrohSignOutFixture {
    static let accountID = "account-a"
    static let tag = "test"
    static let bindingID = "123e4567-e89b-42d3-a456-426614174070"
    static let deviceID = "123e4567-e89b-42d3-a456-426614174071"
    static let firstAppInstanceID = UUID(
        uuidString: "123e4567-e89b-42d3-a456-426614174072"
    )!
    static let secondAppInstanceID = UUID(
        uuidString: "123e4567-e89b-42d3-a456-426614174073"
    )!

    let composition: MobileIrohRuntimeComposition
    let auth: AuthCoordinator
    let authClient: MobileIrohTestAuthClient
    let user: CMUXAuthUser
    let otherUser: CMUXAuthUser
    let appInstances: CmxIrohAppInstanceRepository
    let identities: CmxIrohIdentityRepository
    let brokerCredentials: CmxIrohBrokerCredentialRepository
    let outbox: CmxIrohPendingRevocationOutbox
    let outboxStore: MobileIrohControlledCredentialStore
    let endpointFactory: MobileIrohCountingEndpointFactory
    let endpointFactoryModes: MobileIrohEndpointFactoryModeRecorder
    let debugDefaults: UserDefaults
    let broker: MobileIrohRevocationBroker
    let request: CmxByteTransportRequest
    let initialBindCount: Int
    let appInstanceID: String
    let identity: CmxIrohIdentityMaterial
    let binding: CmxIrohBrokerBindingMetadata
    let pendingRevocation: CmxIrohPendingRevocation

    var accountID: String { Self.accountID }
    var tag: String { Self.tag }
    var bindingID: String { Self.bindingID }

    static func make() async throws -> Self {
        let suiteName = "MobileIrohRuntimeCompositionTests.signout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let installState = CmxIrohUserDefaultsInstallStateStore(defaults: defaults)
        let appInstanceIDs = MobileIrohUUIDSequence([
            firstAppInstanceID,
            secondAppInstanceID,
        ])
        let identityBytes = MobileIrohDataSequence([
            Data(repeating: 7, count: 32),
            Data(repeating: 8, count: 32),
        ])
        let identityStore = MobileIrohInMemoryIdentityStore()
        let brokerStore = MobileIrohControlledCredentialStore()
        let outboxStore = MobileIrohControlledCredentialStore()
        let offlineStore = MobileIrohControlledCredentialStore()
        let appInstances = CmxIrohAppInstanceRepository(
            store: installState,
            makeUUID: { appInstanceIDs.next() }
        )
        let identities = CmxIrohIdentityRepository(
            secureStore: identityStore,
            installState: installState,
            randomBytes: { try identityBytes.next() },
            marker: { "test-install" }
        )
        let brokerCredentials = CmxIrohBrokerCredentialRepository(
            secureStore: brokerStore,
            installState: installState
        )
        let appInstanceID = try await appInstances.appInstanceID(
            accountID: accountID,
            tag: tag
        )
        let identity = try await identities.identity(
            accountID: accountID,
            appInstanceID: appInstanceID
        )
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: identity.secretKey.bytes
        )
        let endpointID = try CmxIrohPeerIdentity(
            endpointID: privateKey.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }
                .joined()
        )
        let binding = try CmxIrohBrokerBindingMetadata(
            bindingID: bindingID,
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            tag: tag,
            platform: .ios,
            endpointID: endpointID,
            identityGeneration: identity.generation
        )
        try await brokerCredentials.saveBinding(binding, accountID: accountID)

        let user = CMUXAuthUser(
            id: accountID,
            primaryEmail: "a@example.com",
            displayName: "A"
        )
        let otherUser = CMUXAuthUser(
            id: "account-b",
            primaryEmail: "b@example.com",
            displayName: "B"
        )
        let authClient = MobileIrohTestAuthClient(user: user)
        let authStore = MobileIrohAuthKeyValueStore()
        let auth = AuthCoordinator(
            client: authClient,
            sessionCache: CMUXAuthSessionCache(
                keyValueStore: authStore,
                key: "has-tokens"
            ),
            userCache: CMUXAuthIdentityStore(
                keyValueStore: authStore,
                key: "cached-user"
            ),
            teamSelection: CMUXAuthTeamSelectionStore(
                keyValueStore: authStore,
                key: "selected-team"
            ),
            anchor: MobileIrohAuthAnchor(),
            config: AuthConfig(
                stack: CMUXAuthConfig(
                    projectId: "test",
                    publishableClientKey: "test"
                ),
                magicLinkCallbackURL: "http://localhost/auth/callback",
                apiBaseURL: "http://localhost"
            ),
            launch: AuthLaunchOptions(
                clearAuthRequested: false,
                mockDataEnabled: false,
                environment: [:],
                includesDevAuth: false
            )
        )
        try await auth.signInWithPassword(
            email: "a@example.com",
            password: "pw"
        )

        let outbox = CmxIrohPendingRevocationOutbox(secureStore: outboxStore)
        let endpointFactory = MobileIrohCountingEndpointFactory()
        let endpointFactoryModes = MobileIrohEndpointFactoryModeRecorder()
        let broker = MobileIrohRevocationBroker()
        let stableDeviceID = deviceID
        let composition = MobileIrohRuntimeComposition(
            appInstances: appInstances,
            identities: identities,
            brokerCredentials: brokerCredentials,
            pendingRevocations: outbox,
            offlinePolicies: CmxIrohClientOfflinePolicyCache(
                secureStore: offlineStore
            ),
            endpointFactory: endpointFactory,
            endpointFactoryProvider: { mode in
                endpointFactoryModes.record(mode)
                return endpointFactory
            },
            brokerFactory: { _ in broker },
            deviceID: { stableDeviceID },
            tag: tag,
            now: { Date(timeIntervalSince1970: 1_000) },
            debugDefaults: defaults
        )
        composition.configure(auth: auth)
        let remoteIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let request = CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "iroh",
                kind: .iroh,
                endpoint: .peer(identity: remoteIdentity, pathHints: []),
                priority: 0
            ),
            expectedPeerDeviceID: "123e4567-e89b-42d3-a456-426614174074",
            authorizationMode: .transportAdmission
        )
        await #expect(throws: CmxIrohClientRuntimeError.self) {
            _ = try await composition.transport(for: request)
        }
        let initialBindCount = await endpointFactory.bindCount()
        #expect(initialBindCount > 0)

        return Self(
            composition: composition,
            auth: auth,
            authClient: authClient,
            user: user,
            otherUser: otherUser,
            appInstances: appInstances,
            identities: identities,
            brokerCredentials: brokerCredentials,
            outbox: outbox,
            outboxStore: outboxStore,
            endpointFactory: endpointFactory,
            endpointFactoryModes: endpointFactoryModes,
            debugDefaults: defaults,
            broker: broker,
            request: request,
            initialBindCount: initialBindCount,
            appInstanceID: appInstanceID,
            identity: identity,
            binding: binding,
            pendingRevocation: try CmxIrohPendingRevocation(
                accountID: accountID,
                tag: tag,
                bindingID: bindingID
            )
        )
    }

    func expectOriginalRepositoriesRemain() async throws {
        #expect(
            try await appInstances.appInstanceID(accountID: accountID, tag: tag)
                == appInstanceID
        )
        #expect(
            try await identities.identity(
                accountID: accountID,
                appInstanceID: appInstanceID
            ) == identity
        )
        #expect(
            try await brokerCredentials.loadBinding(
                accountID: accountID,
                appInstanceID: appInstanceID
            ) == binding
        )
    }

    func expectRepositoriesWereWiped() async throws {
        #expect(
            try await appInstances.appInstanceID(accountID: accountID, tag: tag)
                != appInstanceID
        )
        #expect(
            try await brokerCredentials.loadBinding(
                accountID: accountID,
                appInstanceID: Self.secondAppInstanceID.uuidString.lowercased()
            ) == nil
        )
    }
}

private enum MobileIrohCredentialStoreWriteMode: Sendable {
    case normal
    case fail
    case suspendThenFail
}

private enum MobileIrohSignOutTestError: Error {
    case unavailable
    case writeFailed
    case exhaustedFixture
}

private actor MobileIrohControlledCredentialStore: CmxIrohSecureCredentialStoring {
    private var storage: [String: Data] = [:]
    private var writeMode = MobileIrohCredentialStoreWriteMode.normal
    private var writes = 0
    private var writeStarted = false
    private var writeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendedWrite: CheckedContinuation<Void, Never>?

    func setWriteMode(_ mode: MobileIrohCredentialStoreWriteMode) {
        writeMode = mode
    }

    func read(account: String) -> Data? { storage[account] }

    func write(
        _ data: Data,
        account: String,
        accessibility _: CmxIrohSecureCredentialAccessibility
    ) async throws {
        writes += 1
        switch writeMode {
        case .normal:
            storage[account] = data
        case .fail:
            throw MobileIrohSignOutTestError.writeFailed
        case .suspendThenFail:
            writeStarted = true
            let waiters = writeStartWaiters
            writeStartWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                suspendedWrite = continuation
            }
            throw MobileIrohSignOutTestError.writeFailed
        }
    }

    func delete(account: String) { storage[account] = nil }
    func deleteAll() { storage.removeAll() }

    func waitUntilWriteStarts() async {
        guard !writeStarted else { return }
        await withCheckedContinuation { continuation in
            writeStartWaiters.append(continuation)
        }
    }

    func resumeSuspendedWrite() {
        writeMode = .fail
        suspendedWrite?.resume()
        suspendedWrite = nil
    }

    func writeCount() -> Int { writes }
}

private final class MobileIrohInMemoryIdentityStore: CmxIrohSecureIdentityStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func read(account: String) -> Data? {
        lock.withLock { storage[account] }
    }

    func write(_ data: Data, account: String) {
        lock.withLock { storage[account] = data }
    }

    func delete(account: String) {
        lock.withLock { storage[account] = nil }
    }

    func deleteAll() {
        lock.withLock { storage.removeAll() }
    }
}

private final class MobileIrohUUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) { self.values = values }

    func next() -> UUID {
        lock.withLock {
            guard !values.isEmpty else { return UUID() }
            return values.removeFirst()
        }
    }
}

private final class MobileIrohDataSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data]

    init(_ values: [Data]) { self.values = values }

    func next() throws -> Data {
        try lock.withLock {
            guard !values.isEmpty else {
                throw MobileIrohSignOutTestError.exhaustedFixture
            }
            return values.removeFirst()
        }
    }
}

private actor MobileIrohCountingEndpointFactory: CmxIrohEndpointFactory {
    private var count = 0

    func bind(
        configuration _: CmxIrohEndpointConfiguration
    ) throws -> any CmxIrohEndpoint {
        count += 1
        throw MobileIrohSignOutTestError.unavailable
    }

    func bindCount() -> Int { count }
}

@MainActor
private final class MobileIrohEndpointFactoryModeRecorder {
    private(set) var modes: [CmxIrohTransportVerificationMode] = []

    func record(_ mode: CmxIrohTransportVerificationMode) {
        modes.append(mode)
    }
}

private actor MobileIrohRevocationBroker: CmxIrohClientBrokerServing {
    private var bindingIDs: [String] = []

    func register(
        prepared _: CmxIrohPreparedRegistration,
        signer _: CmxIrohRegistrationSigner
    ) throws -> CmxIrohRegistrationResponse {
        throw MobileIrohSignOutTestError.unavailable
    }

    func discover() throws -> CmxIrohDiscoveryResponse {
        throw MobileIrohSignOutTestError.unavailable
    }

    func issuePairGrant(
        initiatorBindingID _: String,
        acceptorBindingID _: String
    ) throws -> CmxIrohPairGrantResponse {
        throw MobileIrohSignOutTestError.unavailable
    }

    func issueRelayToken(
        bindingID _: String,
        endpointID _: CmxIrohPeerIdentity
    ) throws -> CmxIrohRelayTokenResponse {
        throw MobileIrohSignOutTestError.unavailable
    }

    func revoke(bindingID: String) {
        bindingIDs.append(bindingID)
    }

    func revokedBindingIDs() -> [String] { bindingIDs }
}

private actor MobileIrohCompletionProbe {
    private var finished = false
    func finish() { finished = true }
    func isFinished() -> Bool { finished }
}

private final class MobileIrohAuthKeyValueStore: CMUXAuthKeyValueStore {
    private var storage: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool {
        storage[defaultName] as? Bool ?? false
    }

    func data(forKey defaultName: String) -> Data? {
        storage[defaultName] as? Data
    }

    func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        storage[defaultName] = nil
    }
}

private final class MobileIrohAuthAnchor: NSObject, AuthPresentationAnchoring,
    @unchecked Sendable
{
    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }

    func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

private actor MobileIrohTestAuthClient: AuthClient {
    private var access: String? = "access"
    private var refresh: String? = "refresh"
    private var user: CMUXAuthUser
    private var currentUserCallCount = 0

    init(user: CMUXAuthUser) { self.user = user }

    func setUser(_ user: CMUXAuthUser) { self.user = user }
    func accessToken() -> String? { access }
    func refreshToken() -> String? { refresh }
    func forceRefreshAccessToken() -> String? { access }
    func currentUser(throwOnMissing _: Bool) -> CMUXAuthUser? {
        currentUserCallCount += 1
        return user
    }
    func observedCurrentUserCallCount() -> Int { currentUserCallCount }
    func listTeams() -> [CMUXAuthTeam] { [] }
    func sendMagicLinkEmail(email _: String, callbackURL _: String) -> String { "nonce" }
    func signInWithMagicLink(code _: String) {
        access = "access"
        refresh = "refresh"
    }
    func signInWithCredential(email _: String, password _: String) {
        access = "access"
        refresh = "refresh"
    }
    func signInWithOAuth(
        provider _: String,
        anchor _: any AuthPresentationAnchoring
    ) {
        access = "access"
        refresh = "refresh"
    }
    func storedAccessToken() -> String? { access }
    func clearLocalSession() {
        access = nil
        refresh = nil
    }
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) {
        guard refresh == refreshToken else { return }
        access = nil
        refresh = nil
    }
    func revokeSession(accessToken _: String?, refreshToken _: String?) {}
    func freshAccessToken(
        accessToken: String?,
        refreshToken _: String
    ) -> String? {
        accessToken
    }
}

private func mobileIrohBinding(
    bindingID: String,
    deviceID: String,
    appInstanceID: String,
    endpointID: String,
    platform: String,
    pairingEnabled: Bool,
    tag: String = "test",
    lastSeenAt: String = "2027-07-10T12:00:00.000Z",
    pathHints: [[String: Any]] = []
) -> [String: Any] {
    [
        "binding_id": bindingID,
        "device_id": deviceID,
        "app_instance_id": appInstanceID,
        "tag": tag,
        "platform": platform,
        "endpoint_id": endpointID,
        "identity_generation": 1,
        "pairing_enabled": pairingEnabled,
        "capabilities": ["mobile-rpc-v1"],
        "path_hints": pathHints,
        "last_seen_at": lastSeenAt,
    ]
}

private func mobileIrohDiscovery(
    bindings: [[String: Any]]
) throws -> CmxIrohDiscoveryResponse {
    let rendezvousKey = Data(repeating: 0, count: 32)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let object: [String: Any] = [
        "route_contract_version": 1,
        "bindings": bindings,
        "relay_fleet": [
            "https://aps1-1.relay.lawrence.cmux.iroh.link/",
            "https://euc1-1.relay.lawrence.cmux.iroh.link/",
            "https://use1-1.relay.lawrence.cmux.iroh.link/",
            "https://usw1-1.relay.lawrence.cmux.iroh.link/",
        ],
        "lan_rendezvous": ["generation": 1, "key": rendezvousKey],
        "grant_verification_keys": [
            "version": 1,
            "current_kid": "test-key",
            "keys": [[
                "kid": "test-key",
                "alg": "EdDSA",
                "spki_der_base64": "AA==",
            ]],
        ],
    ]
    return try JSONDecoder().decode(
        CmxIrohDiscoveryResponse.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
}
