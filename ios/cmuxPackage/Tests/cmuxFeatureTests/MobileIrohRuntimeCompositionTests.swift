import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing
@testable import cmuxFeature

@MainActor
@Suite
struct MobileIrohRuntimeCompositionTests {
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
        let state = MobileIrohNetworkPathState()
        let initial = await state.snapshot()

        await state.pathDidChange()
        let changed = await state.snapshot()

        #expect(initial.generation == 1)
        #expect(changed.generation == 2)
        #expect(changed.activeNetworkProfiles.isEmpty)
    }

    @Test
    func verifiedPersonalMacDiscoveryMergesIntoPairedRefreshOnly() async throws {
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
            knownRoutes: { requestedDeviceID in
                guard requestedDeviceID.lowercased() == macDeviceID else { return nil }
                return await base.freshRoutes(forMacDeviceID: requestedDeviceID)
            }
        )

        let routes = try #require(await registry.freshRoutes(forMacDeviceID: macDeviceID))

        #expect(routes.map(\.kind) == [.iroh, .tailscale])
        guard case let .peer(identity, hints) = routes[0].endpoint else {
            Issue.record("Expected an Iroh peer route")
            return
        }
        #expect(identity.endpointID == String(repeating: "a", count: 64))
        #expect(hints.isEmpty)
        #expect(await registry.freshRoutes(forMacDeviceID: "123e4567-e89b-42d3-a456-426614174099")?.map(\.kind) == [.tailscale])
        switch await registry.listDevices() {
        case let .ok(devices): #expect(devices.isEmpty)
        case .authRejected, .transientFailure: Issue.record("Decorator changed the base device-list outcome")
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
        #expect(await catalog.routes(forKnownMacDeviceID: macDeviceID).isEmpty)

        await catalog.replace(with: discovery, scope: 2)
        await catalog.deactivate(scope: 1)
        #expect(await catalog.routes(forKnownMacDeviceID: macDeviceID).count == 1)

        await catalog.deactivate(scope: 2)
        #expect(await catalog.routes(forKnownMacDeviceID: macDeviceID).isEmpty)
    }
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

    func freshRoutes(forMacDeviceID _: String) -> [CmxAttachRoute]? { routes }
    func listDevices() -> DeviceRegistryListOutcome { .ok([]) }
}

private func mobileIrohBinding(
    bindingID: String,
    deviceID: String,
    appInstanceID: String,
    endpointID: String,
    platform: String,
    pairingEnabled: Bool
) -> [String: Any] {
    [
        "binding_id": bindingID,
        "device_id": deviceID,
        "app_instance_id": appInstanceID,
        "tag": "test",
        "platform": platform,
        "endpoint_id": endpointID,
        "identity_generation": 1,
        "pairing_enabled": pairingEnabled,
        "capabilities": ["mobile-rpc-v1"],
        "path_hints": [],
        "last_seen_at": "2027-07-10T12:00:00.000Z",
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
