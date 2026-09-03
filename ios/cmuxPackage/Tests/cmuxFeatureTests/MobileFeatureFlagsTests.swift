import CmuxClientConfig
import Foundation
import Testing

@testable import cmuxFeature

@MainActor
@Suite("Mobile feature flags")
struct MobileFeatureFlagsTests {
    @Test("terminal Files chip ships on and ignores the retired local preference")
    func terminalFilesChipDefaultsOn() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "cmux.mobile.terminalFilesChipEnabled")

        let flags = MobileFeatureFlags(
            loader: QueueClientConfigLoader([.failure(.unavailable)]),
            request: ClientConfigRequest(distinctId: "test"),
            defaults: defaults
        )

        #expect(flags.terminalFilesChipEnabled)
    }

    @Test("remote false disables the chip immediately and survives an outage")
    func terminalFilesChipRemoteKillSwitchCachesLastValue() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let request = ClientConfigRequest(distinctId: "test")
        let disabledThenUnavailable = QueueClientConfigLoader([
            .success(config(terminalFilesChipEnabled: false)),
            .failure(.unavailable),
        ])
        let flags = MobileFeatureFlags(
            loader: disabledThenUnavailable,
            request: request,
            defaults: defaults
        )

        await flags.refresh()
        #expect(!flags.terminalFilesChipEnabled)

        let reloaded = MobileFeatureFlags(
            loader: disabledThenUnavailable,
            request: request,
            defaults: defaults
        )
        #expect(!reloaded.terminalFilesChipEnabled)
        await reloaded.refresh()
        #expect(!reloaded.terminalFilesChipEnabled)
    }

    @Test("successful refreshes update the flag live while evaluation errors preserve it")
    func terminalFilesChipRefreshesLive() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let loader = QueueClientConfigLoader([
            .success(config(terminalFilesChipEnabled: false)),
            .success(config(terminalFilesChipEnabled: true, hasEvaluationErrors: true)),
            .success(config(terminalFilesChipEnabled: true)),
        ])
        let flags = MobileFeatureFlags(
            loader: loader,
            request: ClientConfigRequest(distinctId: "test"),
            defaults: defaults
        )

        await flags.refresh()
        #expect(!flags.terminalFilesChipEnabled)

        await flags.refresh()
        #expect(!flags.terminalFilesChipEnabled)

        await flags.refresh()
        #expect(flags.terminalFilesChipEnabled)
    }

    @Test("control-plane requests are labeled with their trigger and poll cadence")
    func refreshRequestsCarryAttributionLabels() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let loader = QueueClientConfigLoader([
            .success(config(terminalFilesChipEnabled: true)),
            .success(config(terminalFilesChipEnabled: true)),
        ])
        let flags = MobileFeatureFlags(
            loader: loader,
            request: ClientConfigRequest(
                distinctId: "test",
                attribution: ClientConfigAttribution(client: "ios", channel: "dev")
            ),
            defaults: defaults
        )
        defer { flags.stop() }

        await flags.refresh()
        flags.refreshOnForeground()
        await flags.refresh()

        let requests = await loader.requests
        let reasons = requests.compactMap { $0.attribution?.refreshReason }
        #expect(reasons.first == .manual)
        #expect(reasons.contains(.foreground))
        #expect(requests.allSatisfy { $0.attribution?.client == "ios" })
        #expect(requests.allSatisfy { $0.attribution?.pollIntervalSeconds == 30 * 60 })
    }

    @Test("keyboard rebuild revert ships off so legacy pinning is the default")
    func keyboardDockRebuildRevertDefaultsOff() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let flags = MobileFeatureFlags(
            loader: QueueClientConfigLoader([.failure(.unavailable)]),
            request: ClientConfigRequest(distinctId: "test"),
            defaults: defaults
        )

        #expect(!flags.keyboardDockRebuildRevertEnabled)
    }

    @Test("remote keyboard revert applies live and survives an outage")
    func keyboardDockRebuildRevertCachesLastValue() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let request = ClientConfigRequest(distinctId: "test")
        let revertThenUnavailable = QueueClientConfigLoader([
            .success(config(keyboardDockRebuildRevertEnabled: true)),
            .failure(.unavailable),
        ])
        let flags = MobileFeatureFlags(
            loader: revertThenUnavailable,
            request: request,
            defaults: defaults
        )

        await flags.refresh()
        #expect(flags.keyboardDockRebuildRevertEnabled)

        let reloaded = MobileFeatureFlags(
            loader: revertThenUnavailable,
            request: request,
            defaults: defaults
        )
        #expect(reloaded.keyboardDockRebuildRevertEnabled)
        await reloaded.refresh()
        #expect(reloaded.keyboardDockRebuildRevertEnabled)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "MobileFeatureFlagsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func config(
        terminalFilesChipEnabled: Bool = true,
        keyboardDockRebuildRevertEnabled: Bool = false,
        hasEvaluationErrors: Bool = false
    ) -> ClientConfig {
        ClientConfig(
            featureFlags: [
                MobileFeatureFlags.terminalFilesChipFlag.key: .bool(terminalFilesChipEnabled),
                MobileFeatureFlags.keyboardDockRebuildRevertFlag.key: .bool(
                    keyboardDockRebuildRevertEnabled
                ),
            ],
            featureFlagPayloads: [:],
            errorsWhileComputingFlags: hasEvaluationErrors
        )
    }
}

private enum StubClientConfigError: Error, Sendable {
    case unavailable
}

private actor QueueClientConfigLoader: ClientConfigLoading {
    private var results: [Result<ClientConfig, StubClientConfigError>]
    private(set) var requests: [ClientConfigRequest] = []

    init(_ results: [Result<ClientConfig, StubClientConfigError>]) {
        self.results = results
    }

    func load(_ request: ClientConfigRequest) async throws -> ClientConfig {
        requests.append(request)
        guard !results.isEmpty else { throw StubClientConfigError.unavailable }
        return try results.removeFirst().get()
    }
}
