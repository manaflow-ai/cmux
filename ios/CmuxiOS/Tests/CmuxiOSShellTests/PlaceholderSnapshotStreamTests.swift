import CmuxiOSFeatureKit
import CmuxiOSShell
import Testing

@Suite struct PlaceholderSnapshotStreamTests {
    @Test func mapsEverySnapshotAndCarriesConnection() async throws {
        let feed = MockFeedSource()
        let factory = PlaceholderSnapshot.stream(isMock: true, { await feed.updates() }) { items in
            [PlaceholderSection(id: "all", title: nil, rows: items.map {
                PlaceholderRow(id: $0.id, title: $0.title, symbolName: "tray")
            })]
        }
        var iterator = await factory().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.isMock == true)
        #expect(first?.sections.first?.rows.count == MockFixtures.feedItems().count)
        await feed.hub.setConnection(.offline(reason: nil))
        let second = await iterator.next()
        #expect(second?.connection == .offline(reason: nil))
    }
}
