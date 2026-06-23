import CMUXMobileCore
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
    private func makeReady() -> MobilePairingReady {
        MobilePairingReady(
            attachURL: "cmux-ios://attach?ticket=abc",
            macName: "Test Mac",
            tailscaleLines: ["100.64.0.1:7777"],
            manualEntry: CmxManualPairingEntry(host: "100.64.0.1", port: 7777),
            trustedNetworkPairingSecret: "test-pairing-secret"
        )
    }

    private func makeManualOnly() -> MobilePairingManualOnly {
        MobilePairingManualOnly(
            macName: "Test Mac",
            port: 58465,
            trustedNetworkPairingSecret: "test-pairing-secret"
        )
    }

    private func transition(
        from current: MobilePairingModel.State,
        activeConnectionCount: Int,
        baselineConnectionCount: Int
    ) -> MobilePairingModel.State {
        MobilePairingModel.connectionTransition(
            from: current,
            activeConnectionCount: activeConnectionCount,
            baselineConnectionCount: baselineConnectionCount,
            refreshReady: { ready in
                MobilePairingReady(
                    attachURL: ready.attachURL,
                    macName: ready.macName,
                    tailscaleLines: ready.tailscaleLines,
                    manualEntry: ready.manualEntry,
                    trustedNetworkPairingSecret: "refreshed-ready-secret"
                )
            },
            refreshManualOnly: { manual in
                MobilePairingManualOnly(
                    macName: manual.macName,
                    port: manual.port,
                    trustedNetworkPairingSecret: "refreshed-manual-secret"
                )
            }
        )
    }

    @Test("A phone attaching above the baseline flips a displayed ticket to connected")
    func readyFlipsToConnectedOnAttach() {
        let ready = makeReady()
        let next = transition(
            from: .ready(ready),
            activeConnectionCount: 1,
            baselineConnectionCount: 0
        )
        #expect(next == .connected(ready))
        #expect(MobilePairingModel.shouldRevokeManualPairingGrant(from: .ready(ready), to: next))
    }

    @Test("A ready ticket with no new connections stays in the waiting state")
    func readyStaysReadyWithoutConnections() {
        let ready = makeReady()
        let next = transition(
            from: .ready(ready),
            activeConnectionCount: 0,
            baselineConnectionCount: 0
        )
        #expect(next == .ready(ready))
        #expect(!MobilePairingModel.shouldRevokeManualPairingGrant(from: .ready(ready), to: next))
    }

    @Test("Pairing an additional device: an already-connected phone does not flip the new QR")
    func additionalDeviceStaysReadyUntilNewConnectionAboveBaseline() {
        let ready = makeReady()
        // One phone already attached when the QR is shown (baseline 1). The same
        // count must keep showing the QR so a second device can still pair.
        let stillWaiting = transition(
            from: .ready(ready),
            activeConnectionCount: 1,
            baselineConnectionCount: 1
        )
        #expect(stillWaiting == .ready(ready))
        #expect(!MobilePairingModel.shouldRevokeManualPairingGrant(from: .ready(ready), to: stillWaiting))
        // A second device attaches (count rises above the baseline) -> connected.
        let connected = transition(
            from: .ready(ready),
            activeConnectionCount: 2,
            baselineConnectionCount: 1
        )
        #expect(connected == .connected(ready))
        #expect(MobilePairingModel.shouldRevokeManualPairingGrant(from: .ready(ready), to: connected))
    }

    @Test("Connected flips back to ready when the new connection drops to the baseline")
    func connectedFlipsBackToReadyWhenConnectionsDrop() {
        let ready = makeReady()
        let next = transition(
            from: .connected(ready),
            activeConnectionCount: 1,
            baselineConnectionCount: 1
        )
        #expect(next != .ready(ready))
        guard case let .ready(refreshed) = next else {
            Issue.record("expected connected QR state to return to ready")
            return
        }
        #expect(refreshed.trustedNetworkPairingSecret == "refreshed-ready-secret")
    }

    @Test("Connected stays connected while the new phone remains attached")
    func connectedStaysConnectedWithActiveConnections() {
        let ready = makeReady()
        let next = transition(
            from: .connected(ready),
            activeConnectionCount: 2,
            baselineConnectionCount: 1
        )
        #expect(next == .connected(ready))
    }

    @Test("Manual-only pairing flips to connected when a phone attaches")
    func manualOnlyFlipsToConnectedOnAttach() {
        let manual = makeManualOnly()
        let next = transition(
            from: .manualOnly(manual),
            activeConnectionCount: 1,
            baselineConnectionCount: 0
        )
        #expect(next == .connectedManual(manual))
        #expect(MobilePairingModel.shouldRevokeManualPairingGrant(from: .manualOnly(manual), to: next))
    }

    @Test("Manual connected flips back when the connection drops")
    func manualConnectedFlipsBackWhenConnectionsDrop() {
        let manual = makeManualOnly()
        let next = transition(
            from: .connectedManual(manual),
            activeConnectionCount: 0,
            baselineConnectionCount: 0
        )
        #expect(next != .manualOnly(manual))
        guard case let .manualOnly(refreshed) = next else {
            Issue.record("expected connected manual state to return to manual-only")
            return
        }
        #expect(refreshed.trustedNetworkPairingSecret == "refreshed-manual-secret")
    }

    @Test("Preparing is unaffected by connection-count changes")
    func preparingIsUnaffected() {
        let next = transition(
            from: .preparing,
            activeConnectionCount: 1,
            baselineConnectionCount: 0
        )
        #expect(next == .preparing)
    }

    @Test("Signed-out is unaffected by connection-count changes")
    func signedOutIsUnaffected() {
        let next = transition(
            from: .signedOut,
            activeConnectionCount: 1,
            baselineConnectionCount: 0
        )
        #expect(next == .signedOut)
    }
}
