import CMUXMobileCore
import CmuxIrxTransport
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure-projection coverage for the irx-backed Settings Networking snapshot
/// (`MobileHostIrxRuntime+SettingsControl`).
struct MobileHostIrxSettingsMappingTests {
    private let homeRelay = "https://use4.relay.cmux.dev./"
    private let fleet = [
        "https://use4.relay.cmux.dev/",
        "https://usw1.relay.cmux.dev/",
    ]

    @Test func runtimeStatusFollowsLifecyclePhase() {
        #expect(
            MobileHostIrxRuntime.settingsRuntimeStatus(
                phase: .idle, endpointOnline: false, selectedPath: .unavailable
            ) == .inactive)
        #expect(
            MobileHostIrxRuntime.settingsRuntimeStatus(
                phase: .activating, endpointOnline: false, selectedPath: .unavailable
            ) == .starting)
        #expect(
            MobileHostIrxRuntime.settingsRuntimeStatus(
                phase: .failed, endpointOnline: false, selectedPath: .unavailable
            ) == .degraded)
    }

    @Test func activeOnlineRuntimeReportsTheRelayPath() {
        let path = MobileHostIrxRuntime.settingsSelectedPath(
            phase: .active, endpointOnline: true, homeRelayURL: homeRelay)
        #expect(path == .managedRelay(provider: "relay.cmux.dev", region: "USE4"))
        #expect(
            MobileHostIrxRuntime.settingsRuntimeStatus(
                phase: .active, endpointOnline: true, selectedPath: path
            ) == .relayed(provider: "relay.cmux.dev", region: "USE4"))
    }

    @Test func activeRuntimeWithDroppedEndpointReportsStartingNotDegraded() {
        // The accept loop rebinds a dropped endpoint; that transient must not
        // read as a persistent failure.
        #expect(
            MobileHostIrxRuntime.settingsRuntimeStatus(
                phase: .active, endpointOnline: false, selectedPath: .unavailable
            ) == .starting)
        #expect(
            MobileHostIrxRuntime.settingsSelectedPath(
                phase: .active, endpointOnline: false, homeRelayURL: homeRelay
            ) == .unavailable)
    }

    @Test func activeOnlineWithoutHomeRelayReportsEndpointActive() {
        let path = MobileHostIrxRuntime.settingsSelectedPath(
            phase: .active, endpointOnline: true, homeRelayURL: nil)
        #expect(path == .unavailable)
        #expect(
            MobileHostIrxRuntime.settingsRuntimeStatus(
                phase: .active, endpointOnline: true, selectedPath: path
            ) == .active)
    }

    @Test func managedRelaysMarkTheActualHomeRelaySelected() {
        let relays = MobileHostIrxRuntime.settingsManagedRelays(
            relayFleet: fleet, homeRelayURL: homeRelay)
        #expect(relays.map(\.id) == ["use4.relay.cmux.dev", "usw1.relay.cmux.dev"])
        #expect(relays.map(\.isSelected) == [true, false])
        #expect(relays[0].region == "USE4")
        #expect(relays[0].provider == "relay.cmux.dev")
        #expect(relays[0].url == fleet[0])
    }

    @Test func managedRelaysDeduplicateByCanonicalHost() {
        let relays = MobileHostIrxRuntime.settingsManagedRelays(
            relayFleet: [
                "https://use4.relay.cmux.dev/",
                "https://USE4.relay.cmux.dev./",
            ],
            homeRelayURL: nil
        )
        #expect(relays.count == 1)
        #expect(relays.allSatisfy { !$0.isSelected })
    }

    @Test func relayHostCanonicalizesCaseAndFQDNTrailingDot() {
        #expect(
            MobileHostIrxRuntime.relayHost("https://USE4.Relay.cmux.dev./")
                == "use4.relay.cmux.dev")
        #expect(MobileHostIrxRuntime.relayHost("not a url") == nil)
        #expect(MobileHostIrxRuntime.relayHost("https:///nohost") == nil)
    }

    @Test func policySourceIsServerOnlyAfterALiveDiscovery() {
        func snapshot(
            hasTrust: Bool, live: Bool
        ) -> CmxIrohSettingsSnapshot {
            MobileHostIrxRuntime.settingsSnapshot(
                phase: .active,
                forceRelayOnly: false,
                endpointOnline: true,
                homeRelayURL: homeRelay,
                relayFleet: fleet,
                hasTrustSnapshot: hasTrust,
                hadLiveDiscovery: live,
                credentialExpiry: nil
            )
        }
        #expect(snapshot(hasTrust: true, live: true).policySource == .server)
        #expect(snapshot(hasTrust: true, live: false).policySource == .cached)
        #expect(snapshot(hasTrust: false, live: false).policySource == .unavailable)
    }

    @Test func snapshotCarriesCredentialExpiryAsPolicyLifetime() {
        let expiry = Date(timeIntervalSinceReferenceDate: 1_000)
        let snapshot = MobileHostIrxRuntime.settingsSnapshot(
            phase: .active,
            forceRelayOnly: false,
            endpointOnline: true,
            homeRelayURL: homeRelay,
            relayFleet: fleet,
            hasTrustSnapshot: true,
            hadLiveDiscovery: true,
            credentialExpiry: expiry
        )
        #expect(snapshot.policyExpiresAt == expiry)
        #expect(snapshot.preference == .automatic)
        #expect(snapshot.customRelays.isEmpty)
        #expect(snapshot.staleRelayIDs.isEmpty)
        #expect(snapshot.failureDescription == nil)
    }

    @Test func failedPhaseSurfacesAFailureDescriptionForTheAttentionNote() {
        let snapshot = MobileHostIrxRuntime.settingsSnapshot(
            phase: .failed,
            forceRelayOnly: false,
            endpointOnline: false,
            homeRelayURL: nil,
            relayFleet: [],
            hasTrustSnapshot: false,
            hadLiveDiscovery: false,
            credentialExpiry: nil
        )
        #expect(snapshot.runtimeStatus == .degraded)
        #expect(snapshot.failureDescription != nil)
    }

    @MainActor @Test func relayFailureReachesSettingsAndClearsWhenReady() async {
        let message = "Relay connection to relay.example.test failed: UnknownIssuer."
        let runtime = MobileHostIrxRuntime()
        runtime.setSettingsPhase(.failed, error: IrxEndpointError.bindFailed(message))
        let snapshot = await runtime.irohSettingsSnapshot()
        #expect(snapshot.failureDescription == message)
        #expect(runtime.settingsPhase == .failed)
        let updated = "Relay connection to relay.example.test failed: HostnameMismatch."
        runtime.setSettingsPhase(.failed, error: IrxEndpointError.bindFailed(updated))
        #expect(await runtime.irohSettingsSnapshot().failureDescription == updated)
        runtime.setSettingsPhase(.activating)
        #expect(await runtime.irohSettingsSnapshot().failureDescription == updated)
        runtime.setSettingsPhase(.failed)
        #expect(await runtime.irohSettingsSnapshot().failureDescription == updated)
        runtime.setSettingsPhase(.active)
        #expect(await runtime.irohSettingsSnapshot().failureDescription == nil)
    }

    @MainActor @Test func unrelatedErrorsCannotExposeRawCredentialsInSettings() async {
        let runtime = MobileHostIrxRuntime()
        runtime.setSettingsPhase(.failed, error: IrxEndpointError.bindFailed("UnknownIssuer"))
        runtime.setSettingsPhase(.failed, error: NSError(domain: "example", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "https://user:secret@relay.example/path?token=secret",
        ]))
        #expect(runtime.relayFailureDescription == nil)
        let snapshot = await runtime.irohSettingsSnapshot()
        #expect(snapshot.failureDescription?.contains("secret") == false)
        #expect(snapshot.failureDescription?.contains("UnknownIssuer") == false)
    }

    @Test func unsupportedMutationsThrowExplicitly() async {
        let runtime = await MainActor.run { MobileHostIrxRuntime.shared }
        await #expect(throws: MobileHostIrxSettingsUnsupportedError.self) {
            try await runtime.setIrohRelayPreference(.custom)
        }
        await #expect(throws: MobileHostIrxSettingsUnsupportedError.self) {
            try await runtime.removeIrohCustomRelay(id: "any")
        }
        // Automatic already holds under irx, so re-selecting it is an
        // idempotent success rather than a failure.
        await #expect(throws: Never.self) {
            try await runtime.setIrohRelayPreference(.automatic)
        }
    }
}

/// The irx activation retry ladder must honor a broker `Retry-After` floor.
/// Before this coverage, a 429 on `/api/devices/iroh/challenge` was retried on
/// a fixed 5 s cadence (35 rejected mints in 3 minutes on one Mac).
struct MobileHostIrxActivationRetryTests {
    @Test func firstFailureWithoutServerFloorWaitsTheBaseDelay() {
        let delay = MobileHostIrxRuntime.activationRetryDelay(
            after: URLError(.notConnectedToInternet),
            failureCount: 0,
            jitterUnitInterval: 0
        )
        #expect(delay == 5)
    }

    @Test func retryAfterFloorWinsOverTheBaseDelay() {
        let delay = MobileHostIrxRuntime.activationRetryDelay(
            after: CmxRateLimitedError(retryAfterSeconds: 60),
            failureCount: 0,
            jitterUnitInterval: 0
        )
        #expect(delay == 60)
    }

    @Test func repeatedFailuresDoubleUpToTheCap() {
        let third = MobileHostIrxRuntime.activationRetryDelay(
            after: URLError(.timedOut), failureCount: 2, jitterUnitInterval: 0
        )
        let capped = MobileHostIrxRuntime.activationRetryDelay(
            after: URLError(.timedOut), failureCount: 20, jitterUnitInterval: 0
        )
        #expect(third == 20)
        #expect(capped == MobileHostIrxRuntime.maximumActivationRetryDelay)
    }

    @Test func jitterAddsAtMostAQuarterOfTheDelay() {
        let delay = MobileHostIrxRuntime.activationRetryDelay(
            after: CmxRateLimitedError(retryAfterSeconds: 60),
            failureCount: 0,
            jitterUnitInterval: 1
        )
        #expect(delay == 75)
    }
}

@MainActor
struct MobileHostV2ConfigurationTests {
    @Test func emptyPackagedOverridesUseTheBuiltInWorker() throws {
        try withBlankReleaseBundle { bundle, defaults in
            let configuration = try MobileHostV2Configuration.current(
                values: [:], defaults: defaults, bundle: bundle
            )
            #if DEBUG
            #expect(configuration.environment == "development")
            #expect(configuration.baseURL.absoluteString == "https://cmux-v2-development.debussy.workers.dev")
            #else
            #expect(configuration.environment == "production")
            #expect(configuration.baseURL.absoluteString == "https://cmux-v2.debussy.workers.dev")
            #endif
        }
    }

    @Test func blankOverridesDoNotMaskTheProductionEnvironment() throws {
        try withBlankReleaseBundle { bundle, defaults in
            defaults.set("production", forKey: "cmux.iroh.v2.config.CMUX_IROH_V2_ENVIRONMENT")
            let configuration = try MobileHostV2Configuration.current(
                values: ["CMUX_IROH_V2_ENVIRONMENT": " \n", "CMUX_IROH_V2_BASE_URL": ""],
                defaults: defaults,
                bundle: bundle
            )
            #expect(configuration.environment == "production")
            #expect(configuration.baseURL.absoluteString == "https://cmux-v2.debussy.workers.dev")
        }
    }

    @Test func unknownEnvironmentCannotSelectTheDevelopmentWorker() throws {
        try withBlankReleaseBundle { bundle, defaults in
            #expect(throws: V2ControlFailure.scopeMismatch) {
                try MobileHostV2Configuration.current(
                    values: ["CMUX_IROH_V2_ENVIRONMENT": "produciton"],
                    defaults: defaults,
                    bundle: bundle
                )
            }
        }
    }

    private func withBlankReleaseBundle(
        _ body: (Bundle, UserDefaults) throws -> Void
    ) throws {
        let identifier = "com.cmuxterm.configuration-test.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier + ".bundle")
        let defaults = try #require(UserDefaults(suiteName: identifier))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: directory)
        }
        let info: [String: String] = [
            "CFBundleIdentifier": "com.cmuxterm.app.nightly",
            "CMUX_IROH_V2_ENVIRONMENT": "",
            "CMUX_IROH_V2_BASE_URL": ""
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: directory))
        try body(bundle, defaults)
    }
}
