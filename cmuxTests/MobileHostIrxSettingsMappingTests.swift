import CMUXMobileCore
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
