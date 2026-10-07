import CmuxiOSFeatureKit
import Foundation
@testable import CmuxiOSSearchCore
import Testing

@Suite("SearchSession")
@MainActor
struct SearchSessionTests {
    let clock = ManualClock()
    let hosts = MockHostsStore(hosts: [HostRecord(id: HostID("m"), name: "deploy mac", kind: .pairedMac, reachability: .unknown)])

    func makeSession() -> (SearchSession, PublishedResults) {
        let catalog = SearchCatalog(actions: [.newTask], settings: [])
        let session = SearchSession(providers: [catalog.provider, HostSearchProvider(store: hosts)], clock: clock)
        let published = PublishedResults()
        session.onResults = { published.values.append($0) }
        return (session, published)
    }

    /// Lets the session's tasks run until `condition` holds (bounded).
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<2_000 where !condition() { await Task.yield() }
    }

    @Test func debouncesOnTheInjectedClock() async throws {
        let (session, published) = makeSession()
        session.start()
        await settle { session.itemCount == 2 && clock.pendingSleeps == 1 }
        session.setQuery("d")
        session.setQuery("dep")
        await settle { clock.pendingSleeps == 1 }
        #expect(published.values.isEmpty)
        clock.advance(by: .milliseconds(79))
        await settle { false }
        #expect(published.values.isEmpty)
        clock.advance(by: .milliseconds(1))
        await settle { !published.values.isEmpty }
        #expect(published.values.count == 1)
        #expect(published.values.last?.query == "dep")
        #expect(session.results.flat.map(\.id) == ["host:m"])
        session.stop()
    }

    @Test func emptyQueryAnswersAtOnce() async {
        let (session, published) = makeSession()
        session.start()
        await settle { session.itemCount == 2 }
        session.setQuery("new")
        await settle { clock.pendingSleeps == 1 }
        clock.advance(by: .milliseconds(80))
        await settle { published.values.last?.query == "new" }
        #expect(session.results.flat.map(\.id) == ["action:newTask"])
        session.setQuery("")
        #expect(published.values.last?.query == "")
        #expect(session.results.sections.isEmpty)
        session.stop()
    }

    @Test func mirrorChangeReranks() async throws {
        let (session, published) = makeSession()
        session.start()
        await settle { session.itemCount == 2 }
        session.setQuery("box")
        await settle { clock.pendingSleeps == 1 }
        clock.advance(by: .milliseconds(80))
        await settle { false }
        #expect(session.results.flat.isEmpty)
        _ = try await hosts.add(HostDraft(name: "box", kind: .ssh(endpoint: HostEndpoint(address: "b"), jumpHost: nil)),
                                key: IntentKey())
        await settle { session.itemCount == 3 && clock.pendingSleeps == 1 }
        clock.advance(by: .milliseconds(80))
        await settle { !(published.values.last?.flat.isEmpty ?? true) }
        #expect(session.results.flat.map(\.item.title) == ["box"])
        session.stop()
    }

    @Test func stopDropsTheProjection() async {
        let (session, _) = makeSession()
        session.start()
        await settle { session.itemCount == 2 }
        #expect(session.isStarted)
        session.stop()
        #expect(!session.isStarted)
        #expect(session.itemCount == 0)
    }
}

@MainActor
final class PublishedResults {
    var values: [SearchResults] = []
}
