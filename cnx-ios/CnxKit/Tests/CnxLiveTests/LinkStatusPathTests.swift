import CnxTransport
import Foundation
import Testing
@testable import CnxLive

/// VERIFY-round8 Claim 10 (transport switch): the phone said `WireGuard TURN`
/// while the rig's hostd logged `kind=WireGuard path=Direct` with Relay only on.
/// The label is the path the link reports, never the Relay only setting: a
/// relay-only WireGuard link that reports a direct path reads "direct". (The
/// disagreement was hostd's label: the Mac sends plain UDP to a relay-only
/// phone's TURN relayed address and called that Direct; cnx-link `0b6e4f61`
/// and `e8d42d40` label it TURN on the Mac too. The rig's hostd, from
/// `604fc689`, predates them.)
@Suite struct LinkStatusPathTests {
    @Test func theLabelShowsThePathInUseNotTheRelayOnlySetting() {
        var machine = LinkMachine(transport: .wireGuard, relayOnly: true)
        _ = machine.handle(.target(LinkMachine.Target(macID: "m", name: "Studio", isOnline: true)))
        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .direct))
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected · WireGuard direct")
        _ = machine.handle(.linkUpdated(generation: machine.generation, path: .turn, rttMillis: 40))
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected · WireGuard relay (TURN) · 40 ms")
        // UDP blocked: TURN reached over TLS. (There is no WebSocket relay any more.)
        _ = machine.handle(.linkUpdated(generation: machine.generation, path: .turnTLS, rttMillis: nil))
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected · WireGuard relay (TURN over TLS) · 40 ms")
        _ = machine.handle(.linkUpdated(generation: machine.generation, path: .noPath, rttMillis: nil))
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected · WireGuard no path · 40 ms")
    }
}

/// verify/hybrid-link.md: the status line shows the WireGuard link's path and
/// the WebRTC media session beside it ("WireGuard direct · video WebRTC (TURN)").
@Suite struct LinkStatusMediaTests {
    @Test func theLineShowsTheMediaSessionBesideTheLink() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(LinkMachine.Target(macID: "m", name: "Studio", isOnline: true)))
        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .direct))
        _ = machine.handle(.linkUpdated(generation: machine.generation, path: .direct, rttMillis: 14))
        #expect(machine.phase.statusLine(macName: "Studio", media: machine.media) == "Connected · WireGuard direct · 14 ms")
        _ = machine.handle(.mediaUpdated(generation: machine.generation, .up(.turn, rttMillis: 16)))
        #expect(machine.phase.statusLine(macName: "Studio", media: machine.media)
            == "Connected · WireGuard direct · video WebRTC (TURN) · 14 ms")
        _ = machine.handle(.mediaUpdated(generation: machine.generation, .up(.direct, rttMillis: 9)))
        #expect(machine.phase.statusLine(macName: "Studio", media: machine.media)
            == "Connected · WireGuard direct · video WebRTC (direct) · 14 ms")
        // The session failed: video rides the tunnel.
        _ = machine.handle(.mediaUpdated(generation: machine.generation, .failed(reason: "ICE failed")))
        #expect(machine.phase.statusLine(macName: "Studio", media: machine.media)
            == "Connected · WireGuard direct · video in the tunnel · 14 ms")
    }

    @Test func aStaleLinksMediaIsIgnoredAndARedialForgetsIt() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(LinkMachine.Target(macID: "m", name: "Studio", isOnline: true)))
        let first = machine.generation
        _ = machine.handle(.dialSucceeded(generation: first, path: .direct))
        _ = machine.handle(.mediaUpdated(generation: first, .up(.direct, rttMillis: nil)))
        #expect(machine.media == .up(.direct, rttMillis: nil))
        _ = machine.handle(.linkDropped(generation: first, reason: "gone"))
        #expect(machine.media == .off)
        _ = machine.handle(.mediaUpdated(generation: first, .up(.turn, rttMillis: nil)))
        #expect(machine.media == .off)
    }
}
