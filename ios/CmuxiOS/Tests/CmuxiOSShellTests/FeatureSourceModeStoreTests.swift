import CmuxiOSFeatureKit
import CmuxiOSShell
import Foundation
import Testing

@MainActor
@Suite struct FeatureSourceModeStoreTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "a1.modes." + UUID().uuidString)!
    }

    @Test func buildDefaults() {
        let debug = FeatureSourceModeStore(environment: [:], defaults: defaults(), isDebug: true)
        let release = FeatureSourceModeStore(environment: [:], defaults: defaults(), isDebug: false)
        #expect(FeatureSeam.allCases.allSatisfy { debug.mode($0) == .mock })
        #expect(FeatureSeam.allCases.allSatisfy { release.mode($0) == .real })
    }

    @Test func perSeamEnvironmentBeatsGlobal() {
        let store = FeatureSourceModeStore(
            environment: ["CMUX_IOS_SOURCES": "real", "CMUX_IOS_SOURCE_FEED": "mock"], defaults: defaults(), isDebug: true)
        #expect(store.mode(.feed) == .mock)
        #expect(store.mode(.hosts) == .real)
        #expect(store.isPinnedByEnvironment(.hosts))
    }

    @Test func devChoicePersistsAcrossStores() {
        let shared = defaults()
        let first = FeatureSourceModeStore(environment: [:], defaults: shared, isDebug: true)
        var changed = false
        first.onChange = { changed = true }
        first.set(.workspaces, to: .real)
        let second = FeatureSourceModeStore(environment: [:], defaults: shared, isDebug: true)
        #expect(changed)
        #expect(second.mode(.workspaces) == .real)
    }
}
