import Foundation
import Testing
import CMUXMobileCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the Mac device-registry re-registration policy. `statusUpdates()` fires
/// on connection changes as well as route changes, so the client must skip a
/// POST when only the connection set changed (routes identical) and never
/// register an empty (pairing-off) route set. This is the seam that keeps the
/// Mac from spamming `/api/devices` on every phone connect/disconnect.
@Suite struct DeviceRegistryClientTests {
    private func route(host: String, port: Int, id: String = "r") throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port)
        )
    }

    @Test func emptyRoutesNeverRegister() {
        #expect(DeviceRegistryClient.shouldReRegister(previous: nil, current: []) == false)
    }

    @Test func firstNonEmptyRoutesRegister() throws {
        let routes = [try route(host: "100.0.0.1", port: 51000)]
        #expect(DeviceRegistryClient.shouldReRegister(previous: nil, current: routes) == true)
    }

    @Test func identicalRoutesSkipRegistration() throws {
        // A connection-only status tick: same routes, must not re-POST.
        let routes = [try route(host: "100.0.0.1", port: 51000)]
        #expect(DeviceRegistryClient.shouldReRegister(previous: routes, current: routes) == false)
    }

    @Test func changedRoutesReRegister() throws {
        // The Mac moved networks / rebound to a new port.
        let previous = [try route(host: "100.0.0.1", port: 51000)]
        let current = [try route(host: "100.9.9.9", port: 51999)]
        #expect(DeviceRegistryClient.shouldReRegister(previous: previous, current: current) == true)
    }

    @Test func clearingRoutesSkipsRegistration() throws {
        // Pairing turned off after having registered: nothing new to advertise.
        let previous = [try route(host: "100.0.0.1", port: 51000)]
        #expect(DeviceRegistryClient.shouldReRegister(previous: previous, current: []) == false)
    }
}
