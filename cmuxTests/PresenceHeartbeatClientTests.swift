import CMUXMobileCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the presence heartbeat wire body. The heartbeat is the realtime
/// twin of the registry POST: it must always state the full current route set
/// (absent means "unchanged" on the wire, which this client never wants), so
/// the presence DO can push fresh port/IP routes to subscribed phones the
/// moment they change.
@Suite struct PresenceHeartbeatClientTests {
    private func route(host: String, port: Int, id: String = "r") throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port)
        )
    }

    @Test func bodyAlwaysStatesRoutes() throws {
        let routes = [try route(host: "100.0.0.1", port: 51000)]
        let body = PresenceHeartbeatClient.heartbeatBody(
            deviceID: "11111111-2222-4333-8444-555555555555",
            tag: "default",
            bundleID: "com.cmuxterm.app.nightly",
            displayName: "Studio",
            routes: routes,
            stopping: false
        )
        let sent = try #require(body["routes"] as? [[String: Any]])
        #expect(sent.count == 1)
        // Same wire shape as the registry POST: host/port nest under `endpoint`.
        let endpoint = try #require(sent[0]["endpoint"] as? [String: Any])
        #expect(endpoint["host"] as? String == "100.0.0.1")
        #expect(endpoint["port"] as? Int == 51000)
        #expect(body["deviceId"] as? String == "11111111-2222-4333-8444-555555555555")
        #expect(body["platform"] as? String == "mac")
        #expect(body["tag"] as? String == "default")
        #expect(body["displayName"] as? String == "Studio")
        // The bundle id is carried so the phone can label the build channel.
        #expect(body["bundleId"] as? String == "com.cmuxterm.app.nightly")
        #expect(body["stopping"] == nil)
    }

    @Test func emptyRoutesAreStatedNotOmitted() throws {
        // Pairing off: the wire must carry [] ("no routes"), never an absent
        // field (which the service reads as "keep the previous set").
        let body = PresenceHeartbeatClient.heartbeatBody(
            deviceID: "11111111-2222-4333-8444-555555555555",
            tag: "default",
            bundleID: "com.cmuxterm.app.nightly",
            displayName: nil,
            routes: [],
            stopping: false
        )
        let sent = try #require(body["routes"] as? [[String: Any]])
        #expect(sent.isEmpty)
        #expect(body["displayName"] == nil)
    }

    @Test func goodbyeCarriesStoppingAndRoutes() throws {
        let body = PresenceHeartbeatClient.heartbeatBody(
            deviceID: "11111111-2222-4333-8444-555555555555",
            tag: "presvc",
            bundleID: "com.cmuxterm.app.nightly",
            displayName: nil,
            routes: [try route(host: "192.168.1.4", port: 50123)],
            stopping: true
        )
        #expect(body["stopping"] as? Bool == true)
        #expect((body["routes"] as? [[String: Any]])?.count == 1)
    }

    @Test func bodySerializesToJSON() throws {
        let body = PresenceHeartbeatClient.heartbeatBody(
            deviceID: "11111111-2222-4333-8444-555555555555",
            tag: "default",
            bundleID: "com.cmuxterm.app.nightly",
            displayName: "Studio",
            routes: [try route(host: "100.0.0.1", port: 51000)],
            stopping: true
        )
        #expect(JSONSerialization.isValidJSONObject(body))
    }
}
