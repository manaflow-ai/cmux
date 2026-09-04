import CMUXMobileCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Mobile pairing status transition")
struct MobilePairingConnectionTransitionTests {
    private func makeReady() -> MobilePairingModel.Ready {
        MobilePairingModel.Ready(
            attachURL: "cmux-ios://attach?v=2&r=100.64.0.1:7777",
            tailscaleLines: ["100.64.0.1:7777"],
            lanLines: [],
            manualEntry: CmxManualPairingEntry(host: "100.64.0.1", port: 7777),
            reachableViaIroh: true
        )
    }

    /// Routes matching ``makeReady()``, so a transition that recomputes the
    /// diagnostics from them reproduces the same `Ready` value.
    private func matchingRoutes() throws -> [CmxAttachRoute] {
        [try irohRoute(), try tailscaleRoute()]
    }

    @Test("A phone attaching above the baseline flips a displayed ticket to connected")
    func readyFlipsToConnectedOnAttach() throws {
        let ready = makeReady()
        let next = MobilePairingModel.statusTransition(
            from: .ready(ready),
            routes: try matchingRoutes(),
            activeConnectionCount: 1,
            baselineConnectionCount: 0
        )
        #expect(next == .connected(from: .ready(ready)))
    }

    @Test("A ready ticket with no new connections stays in the waiting state")
    func readyStaysReadyWithoutConnections() throws {
        let ready = makeReady()
        let next = MobilePairingModel.statusTransition(
            from: .ready(ready),
            routes: try matchingRoutes(),
            activeConnectionCount: 0,
            baselineConnectionCount: 0
        )
        #expect(next == .ready(ready))
    }

    @Test("Pairing an additional device: an already-connected phone does not flip the new QR")
    func additionalDeviceStaysReadyUntilNewConnectionAboveBaseline() throws {
        let ready = makeReady()
        // One phone already attached when the QR is shown (baseline 1). The same
        // count must keep showing the QR so a second device can still pair.
        let stillWaiting = MobilePairingModel.statusTransition(
            from: .ready(ready),
            routes: try matchingRoutes(),
            activeConnectionCount: 1,
            baselineConnectionCount: 1
        )
        #expect(stillWaiting == .ready(ready))
        // A second device attaches (count rises above the baseline) -> connected.
        let connected = MobilePairingModel.statusTransition(
            from: .ready(ready),
            routes: try matchingRoutes(),
            activeConnectionCount: 2,
            baselineConnectionCount: 1
        )
        #expect(connected == .connected(from: .ready(ready)))
    }

    @Test("Connected flips back to ready when the new connection drops to the baseline")
    func connectedFlipsBackToReadyWhenConnectionsDrop() throws {
        let ready = makeReady()
        let next = MobilePairingModel.statusTransition(
            from: .connected(from: .ready(ready)),
            routes: try matchingRoutes(),
            activeConnectionCount: 1,
            baselineConnectionCount: 1
        )
        #expect(next == .ready(ready))
    }

    @Test("Connected stays connected while the new phone remains attached")
    func connectedStaysConnectedWithActiveConnections() throws {
        let ready = makeReady()
        let next = MobilePairingModel.statusTransition(
            from: .connected(from: .ready(ready)),
            routes: try matchingRoutes(),
            activeConnectionCount: 2,
            baselineConnectionCount: 1
        )
        #expect(next == .connected(from: .ready(ready)))
    }

    @Test("An Iroh-only attach flips the no-Tailscale waiting state to connected")
    func needsReachableTransportFlipsToConnectedOnAttach() throws {
        let next = MobilePairingModel.statusTransition(
            from: .needsReachableTransport(reachableViaIroh: true),
            routes: [try irohRoute()],
            activeConnectionCount: 1,
            baselineConnectionCount: 0
        )
        #expect(next == .connected(
            from: .needsReachableTransport(reachableViaIroh: true)
        ))
    }

    @Test("Connected without a Tailscale route falls back to the no-route waiting state")
    func connectedFallsBackToNeedsReachableTransportWhenConnectionsDrop() throws {
        let next = MobilePairingModel.statusTransition(
            from: .connected(
                from: .needsReachableTransport(reachableViaIroh: true)
            ),
            routes: [try irohRoute()],
            activeConnectionCount: 0,
            baselineConnectionCount: 0
        )
        #expect(next == .needsReachableTransport(reachableViaIroh: true))
    }

    @Test("Ready diagnostics follow route changes while the code stays fixed")
    func readyDiagnosticsFollowRouteChanges() throws {
        let ready = makeReady()
        // Iroh deregisters while the window is open: the diagnostics update,
        // the displayed code does not.
        let next = MobilePairingModel.statusTransition(
            from: .ready(ready),
            routes: [try tailscaleRoute()],
            activeConnectionCount: 0,
            baselineConnectionCount: 0
        )
        guard case let .ready(updated) = next else {
            Issue.record("expected .ready, got \(next)")
            return
        }
        #expect(updated.attachURL == ready.attachURL)
        #expect(updated.reachableViaIroh == false)
        #expect(updated.tailscaleLines == ready.tailscaleLines)
    }

    @Test("The no-route waiting state tracks Iroh registration")
    func needsReachableTransportTracksIrohRegistration() throws {
        let next = MobilePairingModel.statusTransition(
            from: .needsReachableTransport(reachableViaIroh: false),
            routes: [try irohRoute()],
            activeConnectionCount: 0,
            baselineConnectionCount: 0
        )
        #expect(next == .needsReachableTransport(reachableViaIroh: true))
    }

    @Test("Preparing is unaffected by connection-count changes")
    func preparingIsUnaffected() throws {
        let next = MobilePairingModel.statusTransition(
            from: .preparing,
            routes: try matchingRoutes(),
            activeConnectionCount: 1,
            baselineConnectionCount: 0
        )
        #expect(next == .preparing)
    }

    @Test("Signed-out is unaffected by connection-count changes")
    func signedOutIsUnaffected() throws {
        let next = MobilePairingModel.statusTransition(
            from: .signedOut,
            routes: try matchingRoutes(),
            activeConnectionCount: 1,
            baselineConnectionCount: 0
        )
        #expect(next == .signedOut)
    }

    @Test("Tailscale remains the preferred pairing disclosure when Iroh is available")
    func tailscaleRouteWinsWhenIrohIsAvailable() throws {
        let plan = try #require(MobilePairingModel.PairingRoutePlan.make(routes: [
            try irohRoute(),
            try tailscaleRoute()
        ]))

        #expect(plan.disclosureMode == .legacyPrivateNetworkCompatibility)
    }

    @Test("Tailscale remains usable when Iroh is unavailable")
    func tailscaleOnlyPlanRetainsReleasedClientSupport() throws {
        let plan = try #require(MobilePairingModel.PairingRoutePlan.make(routes: [
            try tailscaleRoute()
        ]))

        #expect(plan.disclosureMode == .legacyPrivateNetworkCompatibility)
    }

    @Test("LAN-only pairing uses the current Iroh bootstrap grammar")
    func lanOnlyPlanUsesIrohIdentityCode() throws {
        let plan = try #require(MobilePairingModel.PairingRoutePlan.make(routes: [
            try CmxAttachRoute(
                id: "lan",
                kind: .lan,
                endpoint: .hostPort(host: "192.168.1.20", port: 58_465)
            ),
            try irohRoute()
        ]))
        #expect(plan.disclosureMode == .irohIdentityOnly)
    }

    @Test("LAN-only pairing without an Iroh identity fails closed")
    func lanOnlyPlanWithoutEncryptedBootstrapIsUnavailable() throws {
        #expect(MobilePairingModel.PairingRoutePlan.make(routes: [
            try CmxAttachRoute(
                id: "lan",
                kind: .lan,
                endpoint: .hostPort(host: "192.168.1.20", port: 58_465)
            )
        ]) == nil)
    }

    @Test("Iroh alone does not produce a Mac pairing QR")
    func irohOnlyPlanIsUnavailable() throws {
        #expect(MobilePairingModel.PairingRoutePlan.make(routes: [
            try irohRoute()
        ]) == nil)
    }

    @Test("Loopback alone never produces a physical-device QR")
    func loopbackAloneIsUnavailable() throws {
        let loopback = try CmxAttachRoute(
            id: "debug",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 7777)
        )
        #expect(MobilePairingModel.PairingRoutePlan.make(routes: [loopback]) == nil)
    }

    private func irohRoute() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                pathHints: []
            )
        )
    }

    private func tailscaleRoute() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 7777)
        )
    }
}
