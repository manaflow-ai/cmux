import CmuxiOSFeatureKit
import CmuxiOSPairingCore
import CmuxMobileWire
import CmuxPairing
import Foundation
import Testing

@Suite struct ControlPlaneDeviceRegistryTests {
    let f = PairingFixtures()

    func make() -> (ControlPlaneDeviceRegistry, FakePairingOps, FakePresence, TrustStoreMirror) {
        let ops = FakePairingOps()
        let presence = FakePresence()
        let mirror = TrustStoreMirror()
        let registry = ControlPlaneDeviceRegistry(team: "team_a1", now: { PairingFixtures.now }) {
            PairingRuntime(account: PairingFixtures.account, mirror: mirror, ops: ops, presence: presence)
        }
        return (registry, ops, presence, mirror)
    }

    func next(_ it: inout AsyncStream<SourceSnapshot<[DeviceRecord]>>.Iterator, until: ([DeviceRecord]) -> Bool) async -> SourceSnapshot<[DeviceRecord]>? {
        while let s = await it.next() { if until(s.value) { return s } }
        return nil
    }

    @Test func ownMacIsDiscoveredUntilThisPhonePublishesThenTrusted() async throws {
        let (registry, ops, presence, mirror) = make()
        var updates = await registry.updates().makeAsyncIterator()
        #expect(await updates.next()?.connection == .connecting)
        await mirror.apply(.snapshot(SnapshotFrame(stream: "trust:user_a1", seq: 0, state: try JSONValue(encoding: TrustStoreState()), decided: [])))
        await mirror.apply(.event(try await f.keySet(f.mac, install: "inst_m1", kind: "mac", name: "Studio", host: "host_a1", key: f.macKey, seq: 1)))
        let found = try #require(await next(&updates) { $0.contains { $0.id == "install:inst_m1" } })
        #expect(found.connection == .live(path: nil))
        let mac = try #require(found.value.first { $0.id == "install:inst_m1" })
        #expect(mac.platform == .mac && mac.trust == .discovered)
        #expect(found.value.contains { $0.isThisDevice && $0.id == "install:inst_p1" })
        #expect(presence.asked.last == ["host_a1": "team_a1"])
        // Connect: the registry asks the owner to publish; the trust comes from the owner's event.
        let receipt = try await registry.pair(PairingTicketPayload.device(.install("inst_m1")).ticket, key: IntentKey(rawValue: "k1"))
        guard case .committed(let key, _) = receipt else { Issue.record("expected a commit"); return }
        #expect(key == IntentKey(rawValue: "k1"))
        #expect(await ops.calls == ["publish"])
        await mirror.apply(.event(try await f.keySet(f.phone, install: "inst_p1", kind: "ios", name: "iPhone", host: nil, key: Data(repeating: 3, count: 32), seq: 2)))
        let trusted = try #require(await next(&updates) { $0.first { $0.id == "install:inst_m1" }?.trust == .trusted })
        #expect(trusted.value.filter(\.isThisDevice).count == 1)
        // Presence feeds lastSeen.
        presence.sink.yield(["host_a1": HostPresence(state: .online, at: Date(timeIntervalSince1970: 1_900_000_000))])
        let seen = await next(&updates) { $0.first { $0.id == "install:inst_m1" }?.lastSeen == Date(timeIntervalSince1970: 1_900_000_000) }
        #expect(seen != nil)
    }

    @Test func qrClaimVerifiesTheHostCertAgainstTheScannedKey() async throws {
        let (registry, ops, _, _) = make()
        await ops.script(claim: try await f.claimResult(status: .pending))
        let ok = try await registry.pair(PairingTicketPayload.link(f.link).ticket, key: IntentKey(rawValue: "q1"))
        guard case .committed = ok else { Issue.record("expected a commit"); return }
        #expect(await ops.calls == ["publish", "claim:host_b1"])
        // An owner answering with another key than the QR code bound is refused locally.
        await ops.script(claim: try await f.claimResult(status: .trusted, key: Data(repeating: 9, count: 32)))
        let bad = try await registry.pair(PairingTicketPayload.link(f.link).ticket, key: IntentKey(rawValue: "q2"))
        guard case .refused(_, let reason) = bad else { Issue.record("expected a refusal"); return }
        #expect(!reason.isEmpty)
    }

    @Test func ownerRefusalsAreReceiptsAndOfflineThrows() async throws {
        let (registry, ops, _, _) = make()
        await ops.script(claim: nil, error: PairingClientError(code: "pairing.offer_used", message: "used"))
        let used = try await registry.pair(PairingTicketPayload.link(f.link).ticket, key: IntentKey(rawValue: "r1"))
        guard case .refused = used else { Issue.record("expected a refusal"); return }
        await ops.failPublish(FeatureSourceError.offline)
        await #expect(throws: FeatureSourceError.offline) {
            _ = try await registry.pair(PairingTicketPayload.device(.install("inst_m1")).ticket, key: IntentKey())
        }
        let garbage = try await registry.pair(PairingTicket(payload: Data("hello".utf8)), key: IntentKey(rawValue: "g"))
        guard case .refused = garbage else { Issue.record("expected a refusal"); return }
        let v2 = URL(string: f.link.absoluteString.replacingOccurrences(of: "pair/1", with: "pair/2"))!
        let update = try await registry.pair(PairingTicketPayload.link(v2).ticket, key: IntentKey(rawValue: "v2"))
        #expect(update == .refused(key: IntentKey(rawValue: "v2"), reason: PairingLinkHandler.reason(for: PairingLinkError.unsupportedVersion("2"))))
    }

    @Test func revokeRenameAndAcceptRouteToTheirOwners() async throws {
        let (registry, ops, _, _) = make()
        _ = try await registry.revoke(DeviceRecordID.install("inst_x").rawValue, key: IntentKey())
        _ = try await registry.revoke(DeviceRecordID.remote(host: "host_b1", install: "inst_p1").rawValue, key: IntentKey())
        _ = try await registry.revoke(DeviceRecordID.guest(host: "host_a1", install: "inst_g1").rawValue, key: IntentKey())
        _ = try await registry.rename(DeviceRecordID.install("inst_m1").rawValue, to: "Desk", key: IntentKey())
        _ = try await registry.pair(PairingTicketPayload.device(.request(offerID: "oid")).ticket, key: IntentKey())
        let refused = try await registry.rename(DeviceRecordID.guest(host: "h", install: "i").rawValue, to: "x", key: IntentKey(rawValue: "n"))
        guard case .refused = refused else { Issue.record("expected a refusal"); return }
        #expect(await ops.calls == ["revokeInstall:inst_x", "revoke:host_b1/inst_p1", "revoke:host_a1/inst_g1", "rename:inst_m1=Desk", "accept:oid"])
    }
}
