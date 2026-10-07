import CmuxiOSFeatureKit
import CmuxiOSPairingCore
import CmuxMobileWire
import CmuxPairing
import Foundation
import Testing

@Suite struct DeviceProjectionTests {
    let f = PairingFixtures()

    @Test func projectsRemoteHostsGuestsAndRequests() async throws {
        var state = TrustStoreState()
        try state.apply(try await f.keySet(f.phone, install: "inst_p1", kind: "ios", name: "iPhone", host: nil, key: Data(repeating: 3, count: 32), seq: 1))
        let hostCert = try await f.cert(f.otherMac, user: "user_b1", install: "inst_bm", key: f.otherMacKey)
        try state.apply(f.event("trust.remote.add", [
            "host": .string("host_b1"), "team": .string("team_b1"), "owner_user": .string("user_b1"), "name": .string("Bea's Mac"),
            "host_install": .string("inst_bm"), "public_jwk": try JSONValue(encoding: InstallPublicKey(f.otherMac.key.publicKey)),
            "cert": try JSONValue(encoding: hostCert), "install": .string("inst_p1"), "offer_id": .string("o"),
        ], seq: 2))
        let guestCert = try await f.cert(f.otherMac, user: "user_b1", install: "inst_g1", key: f.macKey)
        var request: [String: JSONValue] = [
            "install": .string("inst_g1"), "user": .string("user_b1"), "user_name": .string("Bea"), "name": .string("iPhone"), "platform": .string("ios"),
            "public_jwk": try JSONValue(encoding: InstallPublicKey(f.otherMac.key.publicKey)), "cert": try JSONValue(encoding: guestCert),
            "offer_id": .string("q"), "host": .string("host_a1"), "host_name": .string("Studio"), "team": .string("team_a1"),
        ]
        request["expires_at"] = .int(1_800_000_600_000)
        try state.apply(f.event("trust.request.add", request, seq: 3))
        let projection = DeviceProjection(account: PairingFixtures.account)
        let records = projection.records(state: state, presence: [:], now: PairingFixtures.now)
        let remote = try #require(records.first { $0.id == "remote:host_b1/inst_p1" })
        #expect(remote.platform == .mac && remote.trust == .trusted)
        let req = try #require(records.first { $0.id == "request:q" })
        #expect(req.trust == .discovered && req.platform == .iPhone && req.name.contains("Bea"))
        #expect(projection.hosts(state: state, team: "team_a1") == ["host_b1": "team_b1"])
        // Expired requests drop out of the list.
        #expect(!projection.records(state: state, presence: [:], now: PairingFixtures.now.addingTimeInterval(3600)).contains { $0.id == "request:q" })
    }

    @Test func ticketPayloadsAndIDsRoundTrip() {
        for id in [DeviceRecordID.install("inst_1"), .remote(host: "h_1", install: "in_2"), .guest(host: "h_1", install: "in_3"), .request(offerID: "abc")] {
            #expect(DeviceRecordID(rawValue: id.rawValue) == id)
            #expect(PairingTicketPayload(ticket: PairingTicketPayload.device(id).ticket) == .device(id))
        }
        let url = URL(string: "cmux://pair/1?o=x")!
        #expect(PairingTicketPayload(ticket: PairingTicketPayload.link(url).ticket) == .link(url))
        #expect(PairingTicketPayload(ticket: PairingTicket(payload: Data("nonsense".utf8))) == nil)
    }

    @Test func linkHandlerMapsRouterLinks() {
        let handler = PairingLinkHandler(now: { PairingFixtures.now })
        if case .claim(_, let name) = handler.action(for: f.link) { #expect(name == "Bea's Mac") } else { Issue.record("expected claim") }
        #expect(handler.action(for: URL(string: "cmux://attach/1?h=host_a1&t=team_a1")!) == .attach(host: "host_a1"))
        if case .refuse = handler.action(for: URL(string: "cmux://pair/9?o=x")!) {} else { Issue.record("expected refuse") }
    }
}
