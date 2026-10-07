import CmuxiOSFeatureKit
@testable import CmuxiOSSSHCore
import Foundation
import Testing

/// Deferred sign-in (e5-extras.md section 5): hosts made signed out stay on
/// the device and are offered for sync on sign-in.
@Suite struct GuestHostsTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guest-\(UUID().uuidString)", isDirectory: true)

    private func draft(_ name: String) -> HostDraft {
        HostDraft(name: name, kind: .ssh(endpoint: HostEndpoint(address: name + ".lan", port: 22, user: "me"), jumpHost: nil))
    }

    @Test func guestAddsAreRecordedAndRemovalsForgotten() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalHostsStore(url: directory.appendingPathComponent("hosts.json"))
        let ledger = GuestHostsLedger(url: directory.appendingPathComponent("guest-hosts.json"))
        let guest = GuestRecordingHostsStore(base: store, ledger: ledger)
        let first = IntentKey(rawValue: "a")
        let second = IntentKey(rawValue: "b")
        _ = try await guest.add(draft("one"), key: first)
        _ = try await guest.add(draft("two"), key: second)
        _ = try await guest.add(draft(""), key: IntentKey(rawValue: "refused"))
        #expect(await ledger.recorded() == [.added(by: first), .added(by: second)])
        _ = try await guest.remove(.added(by: first), key: IntentKey(rawValue: "rm"))
        #expect(await ledger.recorded() == [.added(by: second)])
        let reopened = GuestHostsLedger(url: directory.appendingPathComponent("guest-hosts.json"))
        #expect(await reopened.recorded() == [.added(by: second)])
    }

    @Test func pendingListsOnlyHostsThatStillExist() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = GuestHostsLedger(url: directory.appendingPathComponent("guest-hosts.json"))
        await ledger.record(HostID("kept"))
        await ledger.record(HostID("gone"))
        let records = [HostRecord(id: HostID("kept"), name: "kept", kind: .ssh(endpoint: HostEndpoint(address: "k"), jumpHost: nil),
                                  reachability: .unknown)]
        #expect(await ledger.pending(in: records).map(\.id) == [HostID("kept")])
        await ledger.clear()
        #expect(await ledger.recorded().isEmpty)
    }

    @Test func adoptingRepublishesTheDevicesRecordsOnce() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let sync = RecordingSync()
        let store = LocalHostsStore(url: directory.appendingPathComponent("hosts.json"), sync: sync)
        _ = try await store.add(draft("one"), key: IntentKey(rawValue: "a"))
        let adopter = LocalHostsAdopter(store: store)
        await adopter.adopt([])
        #expect(await sync.published.count == 1)
        await adopter.adopt([.added(by: IntentKey(rawValue: "a"))])
        #expect(await sync.published.map(\.0) == [1, 1])
        #expect(await sync.published.map(\.1) == [1, 1])
    }
}
