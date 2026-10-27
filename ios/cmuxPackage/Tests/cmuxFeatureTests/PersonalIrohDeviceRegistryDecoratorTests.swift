import CMUXMobileCore
import CmuxIrxTransport
import CmuxMobileShell
import CmuxMobileShellModel
import Testing

@testable import cmuxFeature

@MainActor
@Suite("personal Iroh device registry")
struct PersonalIrohDeviceRegistryDecoratorTests {
    @Test("a new account or team cannot read the previous scope before discovery updates",
          arguments: ["account-b:team-b", "account-a:team-b"])
    func accountSwitchFencesRegistryReads(nextScope: String) async throws {
        let fixture = RegistryScopeFixture()
        let provider = makeProvider(fixture)
        let registry = makeRegistry(provider)
        #expect((await provider.discoverLiveMacs()).map(\.deviceID) == ["mac-a"])
        #expect(try await devices(registry).map(\.deviceId) == ["mac-a"])

        await fixture.set(scope: nextScope, directory: directory(macID: "mac-b"))
        #expect(try await devices(registry).isEmpty)
        #expect(await registry.freshRoutes(forMacDeviceID: "mac-a", instanceTag: "default") == nil)

        // Revisions are scoped to the owner. B's revision 1 replaces A's 1.
        #expect((await provider.discoverLiveMacs()).map(\.deviceID) == ["mac-b"])
        #expect(try await devices(registry).map(\.deviceId) == ["mac-b"])
    }

    @Test("sign-out hides cached devices and reconnect routes immediately")
    func signOutFencesRegistryReads() async throws {
        let fixture = RegistryScopeFixture()
        let provider = makeProvider(fixture)
        let registry = makeRegistry(provider)
        #expect((await provider.discoverLiveMacs()).count == 1)
        await fixture.set(scope: nil, directory: nil)
        #expect(try await devices(registry).isEmpty)
        #expect(await registry.freshRoutes(forMacDeviceID: "mac-a", instanceTag: "default") == nil)
    }

    @Test("a temporary discovery failure preserves the current account and recovers at the same revision")
    func sameScopeOutageKeepsVerifiedRoutes() async throws {
        let fixture = RegistryScopeFixture()
        let provider = makeProvider(fixture)
        let registry = makeRegistry(provider)
        #expect((await provider.discoverLiveMacs()).count == 1)
        await fixture.set(scope: "account-a:team-a", directory: nil)
        #expect((await provider.discoverLiveMacs()).isEmpty)
        #expect(try await devices(registry).map(\.deviceId) == ["mac-a"])
        #expect(await registry.freshRoutes(forMacDeviceID: "mac-a", instanceTag: "default")?.count == 1)

        await fixture.set(scope: "account-a:team-a", directory: directory(macID: "mac-a"))
        #expect((await provider.discoverLiveMacs()).map(\.deviceID) == ["mac-a"])
    }

    @Test("a discovery suspended across an account switch cannot expose the old Mac")
    func mismatchedDiscoveryHidesPreviousScope() async throws {
        let fixture = RegistryScopeFixture()
        let provider = makeProvider(fixture)
        let registry = makeRegistry(provider)
        #expect((await provider.discoverLiveMacs()).count == 1)
        await fixture.parkNextDiscovery()
        let pending = Task { await provider.discoverLiveMacs() }
        await fixture.waitUntilParked()
        await fixture.set(scope: "account-b:team-b", directory: directory(macID: "mac-b"))
        await fixture.releaseDiscovery()
        #expect((await pending.value).isEmpty)
        #expect(try await devices(registry).isEmpty)
        #expect((await provider.discoverLiveMacs()).map(\.deviceID) == ["mac-b"])
    }

    @Test("an old discovery completion cannot erase a newer account projection")
    func staleDiscoveryPreservesNewerProjection() async throws {
        let fixture = RegistryScopeFixture()
        let provider = makeProvider(fixture)
        let registry = makeRegistry(provider)
        #expect((await provider.discoverLiveMacs()).count == 1)
        await fixture.parkNextDiscovery()
        let pending = Task { await provider.discoverLiveMacs() }
        await fixture.waitUntilParked()
        await fixture.set(scope: "account-b:team-b", directory: directory(macID: "mac-b"))
        #expect((await provider.discoverLiveMacs()).map(\.deviceID) == ["mac-b"])
        await fixture.releaseDiscovery()
        #expect((await pending.value).isEmpty)
        #expect(try await devices(registry).map(\.deviceId) == ["mac-b"])
    }

    private func makeProvider(_ fixture: RegistryScopeFixture) -> MobileIrxDiscoveryProvider {
        MobileIrxDiscoveryProvider(
            preferredTag: "default", compatibilityPolicy: nil,
            discover: { await fixture.discover() }, invalidateSnapshot: {}, revokeBinding: { _ in },
            authenticatedAccountID: { "account-a" },
            authenticatedScopeID: { await fixture.scope }
        )
    }

    private func makeRegistry(_ provider: MobileIrxDiscoveryProvider) -> PersonalIrohDeviceRegistryDecorator {
        PersonalIrohDeviceRegistryDecorator(catalog: provider.routeCatalog, knownRoutes: { _, _ in nil })
    }

    private func devices(_ registry: PersonalIrohDeviceRegistryDecorator) async throws -> [RegistryDevice] {
        let outcome = await registry.listDevices()
        guard case .ok(let devices) = outcome else {
            Issue.record("Expected a registry snapshot")
            return []
        }
        return devices
    }
}

private func directory(macID: String) -> V2Directory {
    V2Directory(
        devices: [V2DeviceRecord(
            descriptor: V2DeviceDescriptor(
                endpointID: String(repeating: "a", count: 64),
                identity: V2Identity(appNamespace: "dev.cmux.app", buildTag: "default", deviceID: macID,
                    environment: "development", projectID: "project-a", teamID: "team-a", userID: "account-a"),
                identityGeneration: 1,
                metadata: V2DeviceMetadata(appVersion: "1.0", capabilities: ["rpc"], displayName: "Fixture Mac",
                    pairingEnabled: true, platform: .mac, relayURLs: [])
            ),
            deviceRecordID: "record-" + macID, revision: 1, revoked: false
        )],
        issuedAt: 1_800_000_000, permissionExpiresAt: 2_000_000_000,
        relayURLs: [], revision: 1, teamID: "team-a"
    )
}

private actor RegistryScopeFixture {
    private(set) var scope: String? = "account-a:team-a"
    private var response: V2Directory? = directory(macID: "mac-a")
    private var shouldPark = false
    private var parked: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func set(scope: String?, directory: V2Directory?) {
        self.scope = scope
        response = directory
    }

    func discover() async -> V2Directory? {
        let captured = response
        if shouldPark {
            shouldPark = false
            await withCheckedContinuation { continuation in
                parked = continuation
                started?.resume()
                started = nil
            }
        }
        return captured
    }

    func parkNextDiscovery() { shouldPark = true }

    func waitUntilParked() async {
        if parked != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func releaseDiscovery() {
        parked?.resume()
        parked = nil
    }
}
