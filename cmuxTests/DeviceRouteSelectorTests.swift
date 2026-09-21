import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The two halves of the bearer-token rule for device links. Route selection:
/// the token leaves this Mac over a Tailscale peer address only with the
/// pairing store's device-bound grant for that exact peer (or over DEBUG
/// loopback), in the host's priority order, and undialable kinds are skipped,
/// never downgraded. Host identity: the Mac that answers must prove it is the
/// device and app instance the row named before anything is subscribed.
@Suite("Devices: route selection and host identity")
struct DeviceRouteSelectorTests {
    private let studio = SurfaceDeviceInstanceID(deviceID: "22222222-2222-2222-2222-222222222222", tag: "default")

    private func route(
        _ id: String,
        kind: CmxAttachTransportKind,
        host: String,
        port: Int = 51000,
        priority: Int
    ) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: id, kind: kind, endpoint: .hostPort(host: host, port: port), priority: priority)
    }

    /// The grant the pairing store would hold for `route` on `deviceID`.
    private func grant(for route: CmxAttachRoute, deviceID: String? = nil) -> CmxLegacyTailscaleAuthorizationEvidence? {
        guard case let .hostPort(host, port) = route.endpoint else { return nil }
        return try? CmxLegacyTailscaleAuthorizationEvidence(macDeviceID: deviceID ?? studio.deviceID, host: host, port: port)
    }

    @Test("Another Mac's advertised loopback never replaces its Tailscale pairing", arguments: [false, true])
    func remoteMacRequiresTailscalePairing(hasGrant: Bool) throws {
        let loopback = try route("debug_loopback", kind: .debugLoopback, host: "127.0.0.1", priority: 0)
        let tailscale = try route("tailscale", kind: .tailscale, host: "100.64.0.4", priority: 10)
        let selector = DeviceRouteSelector()
        if hasGrant {
            let selection = try selector.select(from: [loopback, tailscale], instance: studio) {
                self.grant(for: $0)
            }
            #expect(selection.route == tailscale)
            #expect(selection.evidence == grant(for: tailscale))
        } else {
            #expect(throws: DeviceRouteSelector.SelectionError.needsAuthorization) {
                try selector.select(from: [loopback, tailscale], instance: studio) { _ in nil }
            }
        }
    }

    @Test("Automatic Iroh uses peer admission without creating a Tailscale bearer grant")
    func automaticIrohPrefersAuthenticatedPeer() throws {
        let iroh = try CmxAttachRoute(
            id: "iroh", kind: .iroh,
            endpoint: .peer(identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)), pathHints: []),
            priority: 10
        )
        let tailscale = try route("ts", kind: .tailscale, host: "100.64.0.1", priority: 0)
        let selection = try DeviceRouteSelector(allowsIroh: true).select(
            from: [tailscale, iroh], instance: studio
        ) { _ in nil }
        #expect(selection.route == iroh)
        #expect(selection.evidence == nil)
        #expect(throws: DeviceRouteSelector.SelectionError.needsAuthorization) {
            try DeviceRouteSelector().select(from: [tailscale, iroh], instance: studio) { _ in nil }
        }
    }

    @Test("Automatic connections never fall back to a saved Tailscale bearer route")
    func automaticTransportDoesNotDowngrade() throws {
        let selector = DeviceRouteSelector(allowsIroh: true, allowsLegacyTailscale: false)
        let tailscale = try route("ts", kind: .tailscale, host: "100.64.0.1", priority: 0)
        #expect(selector.supportedKinds == [.iroh])
        #expect(throws: DeviceRouteSelector.SelectionError.noDialableRoute(kinds: ["tailscale"])) {
            try selector.select(from: [tailscale], instance: studio) { self.grant(for: $0) }
        }
    }

    @Test("A Tailscale route dials only with a device-bound grant for its exact peer")
    func tailscaleNeedsGrant() throws {
        let selector = DeviceRouteSelector(allowsDebugLoopback: false)
        let tailscale = try route("ts", kind: .tailscale, host: "100.64.0.1", priority: 0)
        #expect(throws: DeviceRouteSelector.SelectionError.needsAuthorization) {
            try selector.select(from: [tailscale], instance: studio) { _ in nil }
        }
        let granted = try #require(grant(for: tailscale))
        let selection = try selector.select(from: [tailscale], instance: studio) { _ in granted }
        #expect(selection.route.id == "ts")
        #expect(selection.evidence == granted)
        // A grant for another device, or for another peer, never authorizes this dial.
        let otherDevice = grant(for: tailscale, deviceID: "33333333-3333-3333-3333-333333333333")
        #expect(throws: DeviceRouteSelector.SelectionError.needsAuthorization) {
            try selector.select(from: [tailscale], instance: studio) { _ in otherDevice }
        }
        let otherPeer = try CmxLegacyTailscaleAuthorizationEvidence(macDeviceID: studio.deviceID, host: "100.64.0.9", port: 51000)
        #expect(throws: DeviceRouteSelector.SelectionError.needsAuthorization) {
            try selector.select(from: [tailscale], instance: studio) { _ in otherPeer }
        }
    }

    @Test("The lowest-priority granted Tailscale route wins, ties by id; ungranted routes are passed over")
    func prefersGrantedByPriority() throws {
        let selector = DeviceRouteSelector(allowsDebugLoopback: false)
        let b = try route("b", kind: .tailscale, host: "100.64.0.2", priority: 5)
        let a = try route("a", kind: .tailscale, host: "100.64.0.1", priority: 5)
        let z = try route("z", kind: .tailscale, host: "100.64.0.3", priority: 1)
        let all = try selector.select(from: [b, a, z], instance: studio) { self.grant(for: $0) }
        #expect(all.route.id == "z")
        let tie = try selector.select(from: [b, a], instance: studio) { self.grant(for: $0) }
        #expect(tie.route.id == "a")
        let onlyB = try selector.select(from: [b, a, z], instance: studio) { $0.id == "b" ? self.grant(for: $0) : nil }
        #expect(onlyB.route.id == "b")
        #expect(DeviceRouteSelector.ordered([b, a, z]).map(\.id) == ["z", "a", "b"])
    }

    @Test("Loopback is dialable only when the build allows it and only on a loopback host, with no grant")
    func loopbackPolicy() throws {
        let loop = try route("loop", kind: .debugLoopback, host: "127.0.0.1", priority: 0)
        let selection = try DeviceRouteSelector(allowsDebugLoopback: true).select(from: [loop], instance: studio) { _ in nil }
        #expect(selection.route.id == "loop")
        #expect(selection.evidence == nil)
        #expect(throws: DeviceRouteSelector.SelectionError.noDialableRoute(kinds: ["debug_loopback"])) {
            try DeviceRouteSelector(allowsDebugLoopback: false).select(from: [loop], instance: studio) { _ in nil }
        }
        let spoofed = try route("spoof", kind: .debugLoopback, host: "100.64.0.4", priority: 0)
        #expect(throws: DeviceRouteSelector.SelectionError.noDialableRoute(kinds: ["debug_loopback"])) {
            try DeviceRouteSelector(allowsDebugLoopback: true).select(from: [spoofed], instance: studio) { _ in nil }
        }
    }

    @Test("Priority orders across kinds; an ungranted Tailscale route still lets loopback dial")
    func priorityAcrossKinds() throws {
        let loop = try route("loop", kind: .debugLoopback, host: "127.0.0.1", priority: 0)
        let tailscale = try route("ts", kind: .tailscale, host: "100.64.0.4", priority: 5)
        let selector = DeviceRouteSelector(allowsDebugLoopback: true)
        let byPriority = try selector.select(from: [tailscale, loop], instance: studio) { self.grant(for: $0) }
        #expect(byPriority.route.id == "loop")
        let release = try DeviceRouteSelector(allowsDebugLoopback: false).select(from: [tailscale, loop], instance: studio) { self.grant(for: $0) }
        #expect(release.route.id == "ts")
        let ungranted = try selector.select(from: [tailscale, loop], instance: studio) { _ in nil }
        #expect(ungranted.route.id == "loop")
    }

    @Test("Non-Tailscale hosts and undialable kinds are skipped, never downgraded")
    func skipsUndialableRoutes() throws {
        let selector = DeviceRouteSelector(allowsDebugLoopback: false)
        let lan = try route("lan", kind: .tailscale, host: "192.168.1.20", priority: 0)
        let websocket = try CmxAttachRoute(id: "ws", kind: .websocket, endpoint: .url("wss://relay.example/attach"), priority: 0)
        #expect(throws: DeviceRouteSelector.SelectionError.noDialableRoute(kinds: ["tailscale", "websocket"])) {
            try selector.select(from: [lan, websocket], instance: studio) { self.grant(for: $0) }
        }
        #expect(throws: DeviceRouteSelector.SelectionError.noRoutes) {
            try selector.select(from: [], instance: studio) { _ in nil }
        }
        #expect(selector.supportedKinds == [.tailscale])
        #expect(DeviceRouteSelector(allowsDebugLoopback: true).supportedKinds == [.tailscale, .debugLoopback])
    }

    @Test("The host must prove the exact device and app instance the row dialed")
    func hostIdentity() throws {
        func status(_ object: [String: Any]) throws -> MobileHostStatusResponse {
            try JSONDecoder().decode(MobileHostStatusResponse.self, from: JSONSerialization.data(withJSONObject: object))
        }
        try DeviceLinkHostIdentity.verify(
            status: status(["mac_device_id": studio.deviceID.uppercased(), "mac_instance_tag": " default "]),
            expected: studio
        )
        #expect(throws: DeviceLinkError.identityUnproven) {
            try DeviceLinkHostIdentity.verify(status: status(["capabilities": []]), expected: studio)
        }
        #expect(throws: DeviceLinkError.identityUnproven) {
            try DeviceLinkHostIdentity.verify(status: status(["mac_device_id": studio.deviceID]), expected: studio)
        }
        #expect(throws: DeviceLinkError.identityUnproven) {
            try DeviceLinkHostIdentity.verify(status: status(["mac_device_id": studio.deviceID, "mac_instance_tag": ""]), expected: studio)
        }
        #expect(throws: DeviceLinkError.identityMismatch) {
            try DeviceLinkHostIdentity.verify(status: status(["mac_device_id": studio.deviceID, "mac_instance_tag": "issue-8001"]), expected: studio)
        }
        #expect(throws: DeviceLinkError.identityMismatch) {
            try DeviceLinkHostIdentity.verify(
                status: status(["mac_device_id": "33333333-3333-3333-3333-333333333333", "mac_instance_tag": "default"]),
                expected: studio
            )
        }
        #expect(throws: DeviceLinkError.malformedResponse("mobile.host.status")) {
            try DeviceLinkHostIdentity.verify(statusResponse: Data("nope".utf8), expected: studio)
        }
        let wire = try JSONSerialization.data(withJSONObject: ["mac_device_id": studio.deviceID, "mac_instance_tag": "default", "capabilities": ["x"]])
        try DeviceLinkHostIdentity.verify(statusResponse: wire, expected: studio)
    }
}
