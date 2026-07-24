import CMUXMobileCore
import CmuxIrohTransport
import Foundation
import Testing
@testable import cmuxFeature

@MainActor
@Suite
struct MobileIrohTransportVerificationModeTests {
    @Test
    func iosCompositionResolvesTheReleasePathPreferenceAndDebugOverride() throws {
        let suiteName = "MobileIrohTransportVerificationModeTests.path-preference.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let automatic = MobileIrohRuntimeComposition.initialTransportVerificationMode(
            defaults: defaults
        )
        #expect(automatic == .automatic)

        defaults.set(
            CmxIrohPathPreference.relayOnly.rawValue,
            forKey: CmxIrohPathPreference.defaultsKey
        )
        let relayOnly = MobileIrohRuntimeComposition.initialTransportVerificationMode(
            defaults: defaults
        )
        #expect(relayOnly == .relayOnly)
        #expect(
            !MobileIrohRuntimeComposition.protocolConfiguration(
                for: relayOnly
            ).allowsNATTraversalAfterAdmission
        )

        #if DEBUG
        defaults.set(
            CmxIrohTransportVerificationMode.directOnly.rawValue,
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        #expect(
            MobileIrohRuntimeComposition.initialTransportVerificationMode(
                defaults: defaults
            ) == .directOnly
        )
        #endif
    }

    #if DEBUG
    @Test
    func iosCompositionUsesTheSharedVerificationMode() throws {
        let cases: [(CmxIrohTransportVerificationMode, Bool)] = [
            (.automatic, true),
            (.relayOnly, false),
            (.directOnly, true),
        ]
        for (mode, expectsNATTraversal) in cases {
            let suiteName = "MobileIrohTransportVerificationModeTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(
                mode.rawValue,
                forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
            )

            let resolved = MobileIrohRuntimeComposition.debugTransportVerificationMode(
                defaults: defaults
            )
            let protocolConfiguration = MobileIrohRuntimeComposition.protocolConfiguration(
                for: resolved
            )

            #expect(resolved == mode)
            #expect(
                protocolConfiguration.allowsNATTraversalAfterAdmission
                    == expectsNATTraversal
            )
        }
    }
    #endif
}
