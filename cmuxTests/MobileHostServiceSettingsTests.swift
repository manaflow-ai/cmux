import CMUXMobileCore
import CmuxIrohTransport
import CmuxAuthRuntime
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct MobileHostServiceSettingsTests {
    @Test(arguments: [BuildFlavor.dev, .nightly, .stable])
    func pairingRequiresExplicitCurrentOptIn(buildFlavor: BuildFlavor) throws {
        let suiteName = "MobileHostServiceSettingsTests.v2.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(!MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: buildFlavor))
        defaults.set(true, forKey: "cmuxMobilePairingHostEnabled")
        #expect(!MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: buildFlavor))
        defaults.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)
        #expect(MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: buildFlavor))
        defaults.set(false, forKey: MobileHostService.listeningEnabledDefaultsKey)
        #expect(!MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: buildFlavor))
        #expect(SettingCatalog().mobile.iOSPairingHost.defaultValue == false)
    }

    @Test func configuredPortDefaultsToCatalogDefaultWhenUnset() throws {
        let suiteName = "MobileHostServiceSettingsTests.Port.Default.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expected = SettingCatalog().mobile.iOSPairingPort.defaultValue
        #expect(MobileHostService.configuredPort(defaults: defaults) == expected)
    }

    @Test func configuredPortHonorsValidOverride() throws {
        let suiteName = "MobileHostServiceSettingsTests.Port.Valid.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(9000, forKey: MobileHostService.portDefaultsKey)
        #expect(MobileHostService.configuredPort(defaults: defaults) == 9000)
    }

    @Test(arguments: [0, -1, 70000, 65536])
    func configuredPortFallsBackForOutOfRangeOverride(invalidPort: Int) throws {
        let suiteName = "MobileHostServiceSettingsTests.Port.Invalid.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(invalidPort, forKey: MobileHostService.portDefaultsKey)
        let expected = SettingCatalog().mobile.iOSPairingPort.defaultValue
        #expect(MobileHostService.configuredPort(defaults: defaults) == expected)
    }

    @Test func settingsUseObservedLocalAddressesAndIgnoreLegacyRouteHints() throws {
        let status = MobileHostServiceStatus(
            isRunning: true, port: 58465, configuredPort: 60000,
            usesEphemeralFallback: false, routes: [try CmxAttachRoute(
                id: "retired-tcp", kind: .tailscale,
                endpoint: .hostPort(host: "100.64.0.1", port: 1234))],
            activeConnectionCount: 2, lastErrorDescription: nil,
            pendingPortChange: true,
            localSocketAddresses: ["192.168.1.2:58465", "[fd00::2]:58465", "192.168.1.2:58465"])
        let snapshot = HostSettingsActions.mobilePairingSnapshot(from: status)
        #expect(snapshot.routes.map(\.endpoint) == ["192.168.1.2:58465", "[fd00::2]:58465"])
        #expect(snapshot.boundPort == 58465)
        #expect(snapshot.configuredPort == 60000)
        #expect(snapshot.pendingPortChange)
    }

    @Test func splitSocketAddressParsesSocketLiteralsOnly() throws {
        let v4 = try #require(HostSettingsActions.splitSocketAddress("93.184.216.34:58465"))
        #expect(v4.host == "93.184.216.34")
        #expect(v4.port == 58_465)
        let v6 = try #require(HostSettingsActions.splitSocketAddress("[2606:4700::6810:1]:443"))
        #expect(v6.host == "2606:4700::6810:1")
        #expect(v6.port == 443)
        #expect(HostSettingsActions.splitSocketAddress("no-port")?.host == nil)
        #expect(HostSettingsActions.splitSocketAddress("2606:4700::6810:1:443")?.host == nil)
        #expect(HostSettingsActions.splitSocketAddress("[2606:4700::6810:1]443")?.host == nil)
        #expect(HostSettingsActions.splitSocketAddress("93.184.216.34:0")?.host == nil)
    }
}

#if DEBUG
@Suite(.serialized)
@MainActor
struct MobileHostMacScopedMutationAuthorizationTests {
    @Test func ignoresUnknownAttachTokenForBroadWorkspaceRequests() async {
        let service = MobileHostService.shared
        service.debugConfigureAcceptedStackAuthTokenForTesting("cmux-dev-token")
        defer { service.debugConfigureAcceptedStackAuthTokenForTesting(nil) }
        for method in ["workspace.list", "workspace.create"] {
            let request = MobileHostRPCRequest(
                id: method,
                method: method,
                params: [:],
                auth: MobileHostRPCAuth(attachToken: "stale-ticket", stackAccessToken: "cmux-dev-token")
            )
            let result = await service.debugAuthorizationError(for: request)
            #expect(result == nil)
        }
    }

}
#endif

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct MobileHostV2LifecycleTests {
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
        let name = "MobileHostV2LifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

    private func waitForSubscription(_ runtime: MobileHostRuntimeProbe) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while runtime.subscriberCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(runtime.subscriberCount > 0)
    }

    @Test func savingPortLeavesTheCurrentEndpointRunning() async throws {
        try await withDefaults { defaults in
            let runtime = MobileHostRuntimeProbe(state: .init(phase: .ready, boundPort: 58465, preferredPort: 58465))
            let service = MobileHostService(defaults: defaults, runtime: runtime)
            #expect(await service.applyConfiguredPort(60001) == .savedForLater)
            #expect(MobileHostService.configuredPort(defaults: defaults) == 60001)
            let status = service.statusSnapshot()
            #expect(status.isRunning)
            #expect(status.port == 58465)
            #expect(status.pendingPortChange)
            #expect(!status.usesEphemeralFallback)
            #expect(runtime.startCount == 0)
            #expect(runtime.stopCount == 0)
            #expect(await service.applyConfiguredPort(58465) == .applied(58465))
            #expect(!service.statusSnapshot().pendingPortChange)
        }
    }

    @Test func disabledAndInvalidPortEditsCannotStartNetworking() async throws {
        try await withDefaults { defaults in
            let runtime = MobileHostRuntimeProbe(allowed: false)
            let service = MobileHostService(defaults: defaults, runtime: runtime)
            #expect(await service.applyConfiguredPort(60001) == .savedForLater)
            #expect(await service.applyConfiguredPort(0) == .invalid)
            #expect(MobileHostService.configuredPort(defaults: defaults) == 60001)
            #expect(!service.statusSnapshot().isRunning)
            #expect(runtime.startCount == 0)
            #expect(runtime.stopCount == 0)
        }
    }

    @Test func readinessWaitsForTheActualIROHReadyEvent() async throws {
        try await withDefaults { defaults in
            let runtime = MobileHostRuntimeProbe()
            let service = MobileHostService(defaults: defaults, runtime: runtime)
            let waiting = Task { await service.ensureListeningAndReady() }
            try await waitForSubscription(runtime)
            #expect(!service.statusSnapshot().isRunning)
            runtime.emit(.init(phase: .ready, boundPort: 60002, preferredPort: 58465))
            let status = await waiting.value
            #expect(status.isRunning)
            #expect(status.port == 60002)
            #expect(status.usesEphemeralFallback)
            #expect(runtime.startCount == 1)
        }
    }

    @Test func cancellingOrTimingOutReadinessDoesNotStopTheListenerOwner() async throws {
        try await withDefaults { defaults in
            let runtime = MobileHostRuntimeProbe()
            let service = MobileHostService(defaults: defaults, runtime: runtime)
            let waiting = Task { await service.ensureListeningAndReady() }
            try await waitForSubscription(runtime)
            waiting.cancel()
            #expect(await waiting.value.isRunning == false)
            #expect(runtime.stopCount == 0)
            #expect(await service.ensureListeningAndReady(timeout: .milliseconds(10)).isRunning == false)
            #expect(runtime.stopCount == 0)
        }
    }

    @Test func disabledPolicyHidesAnOldReadySnapshotImmediately() async throws {
        try await withDefaults { defaults in
            let runtime = MobileHostRuntimeProbe(allowed: false,
                state: .init(phase: .ready, boundPort: 58465, preferredPort: 58465))
            let service = MobileHostService(defaults: defaults, runtime: runtime)
            let status = service.statusSnapshot()
            #expect(!status.isRunning)
            #expect(status.port == nil)
            #expect(status.routes.isEmpty)
            #expect(!status.pendingPortChange)
        }
    }
}

@MainActor
private final class MobileHostRuntimeProbe: MobileHostPairingRuntime {
    var isNetworkingAllowed: Bool
    var listenerState: MobileHostListenerState
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var subscribers: [UUID: AsyncStream<MobileHostListenerState>.Continuation] = [:]
    var subscriberCount: Int { subscribers.count }

    init(allowed: Bool = true, state: MobileHostListenerState = .init()) {
        isNetworkingAllowed = allowed
        listenerState = state
    }

    func configure(auth: AuthCoordinator) {}
    func applyManagedNetworkingPolicy() async {
        startCount += 1
        if isNetworkingAllowed, listenerState.phase == .stopped { emit(.init(phase: .starting)) }
    }
    func prepareForStop() { emit(.init()) }
    func stopHost() async { stopCount += 1; emit(.init()) }
    func foreground() async {}
    func emit(_ state: MobileHostListenerState) {
        listenerState = state
        for subscriber in subscribers.values { subscriber.yield(state) }
    }
    func listenerStateUpdates() -> AsyncStream<MobileHostListenerState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(listenerState)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.subscribers.removeValue(forKey: id) }
            }
        }
    }
}
