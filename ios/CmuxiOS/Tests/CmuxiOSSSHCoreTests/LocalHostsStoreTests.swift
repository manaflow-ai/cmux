import CmuxiOSFeatureKit
@testable import CmuxiOSSSHCore
import Foundation
import Testing

actor RecordingSync: HostsSyncChannel {
    private(set) var published: [(UInt64, Int)] = []
    func publish(_ hosts: [HostRecord], revision: UInt64) async { published.append((revision, hosts.count)) }
}

@Suite struct LocalHostsStoreTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID().uuidString).json")

    func ssh(_ name: String, _ address: String, jump: HostID? = nil) -> HostDraft {
        HostDraft(name: name, kind: .ssh(endpoint: HostEndpoint(address: address, port: 22, user: "me"), jumpHost: jump))
    }

    func committedRevision(_ receipt: IntentReceipt) -> UInt64? {
        if case .committed(_, let revision) = receipt { return revision }
        return nil
    }

    func refusal(_ receipt: IntentReceipt) -> String? {
        if case .refused(_, let reason) = receipt { return reason }
        return nil
    }

    @Test func addIsIdempotentAndPersists() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let sync = RecordingSync()
        let store = LocalHostsStore(url: url, sync: sync)
        let key = IntentKey(rawValue: "add-1")
        let first = try await store.add(ssh("  box ", " box.lan "), key: key)
        let replay = try await store.add(ssh("box", "box.lan"), key: key)
        #expect(committedRevision(first) == 1)
        #expect(replay == first)
        let records = await store.current()
        #expect(records.map(\.id) == [.added(by: key)])
        #expect(records.first?.name == "box")
        #expect(records.first?.kind == .ssh(endpoint: HostEndpoint(address: "box.lan", port: 22, user: "me"), jumpHost: nil))
        #expect(await sync.published.map(\.0) == [1])

        let reopened = LocalHostsStore(url: url)
        #expect(await reopened.current() == records)
        var iterator = await reopened.updates().makeAsyncIterator()
        let snapshot = await iterator.next()
        #expect(snapshot?.revision == 1)
        #expect(snapshot?.connection == .live(path: nil))
    }

    @Test func refusesPairedMacsEmptyFieldsAndUnknownJumps() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalHostsStore(url: url)
        #expect(refusal(try await store.add(HostDraft(name: "Mac", kind: .pairedMac), key: IntentKey())) == HostsRefusal.pairedMac.rawValue)
        #expect(refusal(try await store.add(ssh(" ", "a"), key: IntentKey())) == HostsRefusal.emptyName.rawValue)
        #expect(refusal(try await store.add(ssh("a", ""), key: IntentKey())) == HostsRefusal.emptyAddress.rawValue)
        #expect(refusal(try await store.add(ssh("a", "a", jump: HostID("nope")), key: IntentKey())) == HostsRefusal.unknownJumpHost.rawValue)
        #expect(await store.current().isEmpty)
        var iterator = await store.updates().makeAsyncIterator()
        #expect(await iterator.next()?.revision == 0)
    }

    @Test func jumpCyclesAreRefused() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalHostsStore(url: url)
        let keyA = IntentKey(rawValue: "a"), keyB = IntentKey(rawValue: "b")
        _ = try await store.add(ssh("a", "a.lan"), key: keyA)
        _ = try await store.add(ssh("b", "b.lan", jump: .added(by: keyA)), key: keyB)
        let loop = try await store.update(.added(by: keyA), with: ssh("a", "a.lan", jump: .added(by: keyB)), key: IntentKey())
        #expect(refusal(loop) == HostsRefusal.jumpCycle.rawValue)
        let selfJump = try await store.update(.added(by: keyA), with: ssh("a", "a.lan", jump: .added(by: keyA)), key: IntentKey())
        #expect(refusal(selfJump) == HostsRefusal.jumpCycle.rawValue)
    }

    @Test func removeClearsJumpReferencesAndBroadcasts() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalHostsStore(url: url)
        let keyA = IntentKey(rawValue: "a"), keyB = IntentKey(rawValue: "b")
        _ = try await store.add(ssh("a", "a.lan"), key: keyA)
        _ = try await store.add(ssh("b", "b.lan", jump: .added(by: keyA)), key: keyB)
        let stream = await store.updates()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.revision == 2)
        #expect(committedRevision(try await store.remove(.added(by: keyA), key: IntentKey())) == 3)
        let snapshot = await iterator.next()
        #expect(snapshot?.revision == 3)
        #expect(snapshot?.value.first?.kind == .ssh(endpoint: HostEndpoint(address: "b.lan", port: 22, user: "me"), jumpHost: nil))
        #expect(refusal(try await store.remove(.added(by: keyA), key: IntentKey())) == HostsRefusal.unknownHost.rawValue)
    }

    @Test func turningAJumpHostIntoADirectHostClearsItsUsers() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalHostsStore(url: url)
        let keyA = IntentKey(rawValue: "a")
        _ = try await store.add(ssh("a", "a.lan"), key: keyA)
        _ = try await store.add(ssh("b", "b.lan", jump: .added(by: keyA)), key: IntentKey())
        _ = try await store.update(.added(by: keyA), with: HostDraft(name: "a", kind: .direct(endpoint: HostEndpoint(address: "a.lan"))), key: IntentKey())
        let records = await store.current()
        #expect(records[1].kind == .ssh(endpoint: HostEndpoint(address: "b.lan", port: 22, user: "me"), jumpHost: nil))
    }

    @Test func applyRemoteDropsPairedMacsAndDanglingJumps() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalHostsStore(url: url)
        await store.applyRemote([
            HostRecord(id: HostID("mac"), name: "Mac", kind: .pairedMac, reachability: .unknown),
            HostRecord(id: HostID("x"), name: "x", kind: .ssh(endpoint: HostEndpoint(address: "x"), jumpHost: HostID("gone")), reachability: .unknown),
        ])
        let records = await store.current()
        #expect(records.map(\.id) == [HostID("x")])
        #expect(records.first?.kind == .ssh(endpoint: HostEndpoint(address: "x"), jumpHost: nil))
    }
}
