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
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected · WireGuard TURN · 40 ms")
        _ = machine.handle(.linkUpdated(generation: machine.generation, path: .relay, rttMillis: nil))
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected · WireGuard relay · 40 ms")
    }
}
