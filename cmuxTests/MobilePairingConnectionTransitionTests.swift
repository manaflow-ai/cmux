import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Mobile pairing connection transition")
struct MobilePairingConnectionTransitionTests {
    private func makeReady() -> MobilePairingModel.Ready {
        MobilePairingModel.Ready(
            attachURL: "cmux-ios://attach?ticket=abc",
            macName: "Test Mac",
            tailscaleLines: ["100.64.0.1:7777"]
        )
    }

    @Test("A connected phone flips a displayed ticket from ready to connected")
    func readyFlipsToConnectedOnAttach() {
        let ready = makeReady()
        let next = MobilePairingModel.connectionTransition(
            from: .ready(ready),
            activeConnectionCount: 1
        )
        #expect(next == .connected(ready))
    }

    @Test("A ready ticket with no connections stays in the waiting state")
    func readyStaysReadyWithoutConnections() {
        let ready = makeReady()
        let next = MobilePairingModel.connectionTransition(
            from: .ready(ready),
            activeConnectionCount: 0
        )
        #expect(next == .ready(ready))
    }

    @Test("Losing the last connection flips connected back to ready so the QR returns")
    func connectedFlipsBackToReadyWhenConnectionsDrop() {
        let ready = makeReady()
        let next = MobilePairingModel.connectionTransition(
            from: .connected(ready),
            activeConnectionCount: 0
        )
        #expect(next == .ready(ready))
    }

    @Test("Connected stays connected while a phone remains attached")
    func connectedStaysConnectedWithActiveConnections() {
        let ready = makeReady()
        let next = MobilePairingModel.connectionTransition(
            from: .connected(ready),
            activeConnectionCount: 2
        )
        #expect(next == .connected(ready))
    }

    @Test("Preparing is unaffected by connection-count changes")
    func preparingIsUnaffected() {
        let next = MobilePairingModel.connectionTransition(
            from: .preparing,
            activeConnectionCount: 1
        )
        #expect(next == .preparing)
    }

    @Test("Signed-out is unaffected by connection-count changes")
    func signedOutIsUnaffected() {
        let next = MobilePairingModel.connectionTransition(
            from: .signedOut,
            activeConnectionCount: 1
        )
        #expect(next == .signedOut)
    }
}
