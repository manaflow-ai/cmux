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

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "MobileFeatureFlagsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func config(
        terminalFilesChipEnabled: Bool,
        hasEvaluationErrors: Bool = false
    ) -> ClientConfig {
        ClientConfig(
            featureFlags: [
                MobileFeatureFlags.terminalFilesChipFlag.key: .bool(terminalFilesChipEnabled),
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

    init(_ results: [Result<ClientConfig, StubClientConfigError>]) {
        self.results = results
    }

    func load(_ request: ClientConfigRequest) async throws -> ClientConfig {
        guard !results.isEmpty else { throw StubClientConfigError.unavailable }
        return try results.removeFirst().get()
    }
}
