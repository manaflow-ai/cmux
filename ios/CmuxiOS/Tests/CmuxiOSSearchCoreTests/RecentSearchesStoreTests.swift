import Foundation
@testable import CmuxiOSSearchCore
import Testing

@Suite("RecentSearchesStore")
@MainActor
struct RecentSearchesStoreTests {
    let defaults: UserDefaults

    init() {
        let suite = "cmux.search.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func newestFirstDedupedAndCapped() {
        let store = RecentSearchesStore(defaults: defaults, limit: 3)
        for query in ["api", "deploy", "  ", "logs", "API", "café"] { store.record(query) }
        #expect(store.queries == ["café", "API", "logs"])
        store.record("Cafe")
        #expect(store.queries == ["Cafe", "API", "logs"])
    }

    @Test func persistsAcrossInstances() {
        let store = RecentSearchesStore(defaults: defaults)
        store.record("deploy")
        store.record("api")
        #expect(RecentSearchesStore(defaults: defaults).queries == ["api", "deploy"])
    }

    @Test func removeAndClear() {
        let store = RecentSearchesStore(defaults: defaults)
        store.record("deploy")
        store.record("api")
        store.remove("DEPLOY")
        #expect(store.queries == ["api"])
        store.clear()
        #expect(store.queries.isEmpty)
        #expect(RecentSearchesStore(defaults: defaults).queries.isEmpty)
    }
}
