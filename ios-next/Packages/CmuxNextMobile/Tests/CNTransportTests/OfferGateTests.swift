@testable import CNTransportWebRTC
import Testing

@Suite struct OfferGateTests {
    @Test func offlineHostWaitsForPresenceThenResendsAtOnce() {
        var gate = OfferGate()
        #expect(gate.start(hostOnline: false) == .none)  // host reconnecting: hold the offer
        #expect(gate.answerTimedOut() == .none)          // no 3 s failure while it is known offline
        #expect(gate.presence(online: true) == .send)    // presence online: send now
        #expect(gate.sends == 1)
        #expect(gate.presence(online: true) == .none)    // a repeat does not resend
    }

    @Test func hostOfflineErrorForASentOfferResendsOnPresence() {
        var gate = OfferGate()
        #expect(gate.start(hostOnline: true) == .send)
        #expect(gate.hostOffline() == .none)
        #expect(gate.answerTimedOut() == .none)
        #expect(gate.presence(online: false) == .none)
        #expect(gate.presence(online: true) == .send)
        #expect(gate.sends == 2)
    }

    @Test func missingAnswerFromAnOnlineHostStillFails() {
        var gate = OfferGate()
        #expect(gate.start(hostOnline: nil) == .send)
        #expect(gate.answerTimedOut() == .fail)          // the 3 s fallback stays
    }

    @Test func answeredLinkIgnoresPresence() {
        var gate = OfferGate()
        _ = gate.start(hostOnline: true)
        gate.answerReceived()
        #expect(gate.presence(online: false) == .none)
        #expect(gate.presence(online: true) == .none)
        #expect(gate.answerTimedOut() == .none)
    }
}
