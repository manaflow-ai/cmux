import CmuxiOSFeatureKit
import Testing

@Suite struct MockSnapshotHubTests {
    @Test func streamYieldsCurrentSnapshotFirst() async {
        let hub = MockSnapshotHub([1, 2])
        var iterator = await hub.stream().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.value == [1, 2])
        #expect(first?.revision == 1)
    }

    @Test func commitBumpsRevisionAndBroadcasts() async throws {
        let hub = MockSnapshotHub([Int]())
        var iterator = await hub.stream().makeAsyncIterator()
        _ = await iterator.next()
        let revision = try await hub.commit { $0.append(7) }.revision
        let next = await iterator.next()
        #expect(revision == 2)
        #expect(next?.revision == 2)
        #expect(next?.value == [7])
    }

    @Test func refusalLeavesValueAndRevision() async throws {
        let hub = MockSnapshotHub([1])
        let key = IntentKey()
        let receipt = try await hub.receipt(for: key) { values in
            values.append(2)
            throw MockRefusal("no")
        }
        #expect(receipt == .refused(key: key, reason: "no"))
        let current = await hub.current
        #expect(current.value == [1])
        #expect(current.revision == 1)
    }

    @Test func offlineRefusesEveryChangeWithoutQueueing() async throws {
        let hub = MockSnapshotHub([1])
        await hub.setConnection(.offline(reason: nil))
        await #expect(throws: FeatureSourceError.offline) {
            try await hub.commit { $0.append(2) }
        }
        await hub.setConnection(.live(path: "mock"))
        #expect(await hub.current.value == [1])
    }

    @Test func slowSubscriberKeepsOnlyNewestSnapshot() async throws {
        let hub = MockSnapshotHub(0)
        let stream = await hub.stream()
        for _ in 0..<5 { try await hub.commit { $0 += 1 } }
        var iterator = stream.makeAsyncIterator()
        let snapshot = await iterator.next()
        #expect(snapshot?.value == 5)
        #expect(snapshot?.revision == 6)
    }
}
