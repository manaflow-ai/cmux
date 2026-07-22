import CMUXMobileCore
import CmuxIrohTransport
import Foundation
import Testing
@testable import cmuxFeature

@MainActor
@Suite
struct MobileIrohTransportVerificationModeTests {
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
