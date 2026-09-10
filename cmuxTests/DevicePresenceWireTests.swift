import CMUXMobileCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Devices directory reads two wires: the presence worker's subscribe
/// socket (presence edges plus the `devices` sync collection) and the durable
/// registry (`GET /api/devices`). Both must tolerate what a newer worker or an
/// older Mac emits: unknown frame types, unknown route kinds, missing fields.
@Suite("Devices: presence and registry wire parsing")
struct DevicePresenceWireTests {
    private let uuid = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"

    private func frame(_ object: [String: Any]) throws -> DevicePresenceFrame {
        try DevicePresenceFrame.parse(JSONSerialization.data(withJSONObject: object))
    }

    @Test("A malformed presence snapshot cannot clear the directory")
    func malformedSnapshotIsIgnored() throws {
        #expect(try frame(["type": "snapshot"]) == .ignored)
        #expect(try frame(["type": "snapshot", "devices": "invalid"]) == .ignored)
        #expect(try frame(["type": "snapshot", "devices": []]) == .snapshot(devices: []))
    }

    @Test("Credentialed presence rejects cleartext remote service endpoints")
    func rejectsCleartextRemotePresence() throws {
        #expect(DevicePresenceSubscriber.subscribeURL(serviceBaseURL: try #require(URL(string: "http://presence.example.test"))) == nil)
        #expect(DevicePresenceSubscriber.subscribeURL(serviceBaseURL: try #require(URL(string: "ws://presence.example.test"))) == nil)
    }

    @Test("A snapshot lists every instance and drops only the route entries this build cannot decode")
    func snapshotKeepsInstancesWithUnknownRoutes() throws {
        let parsed = try frame([
            "type": "snapshot",
            "devices": [[
                "deviceId": uuid,
                "instances": [[
                    "deviceId": uuid, "tag": "default", "platform": "mac", "displayName": "Studio",
                    "bundleId": "com.cmuxterm.app", "online": true, "lastSeenAt": 1_700_000_000_000,
                    "routes": [
                        ["id": "ts", "kind": "tailscale", "endpoint": ["type": "host_port", "host": "100.64.0.9", "port": 51000], "priority": 10],
                        ["id": "future", "kind": "quantum", "endpoint": ["type": "wormhole"], "priority": 0],
                    ],
                ], [
                    "deviceId": uuid, "tag": "issue-8001", "online": false, "lastSeenAt": 1_699_000_000_000,
                ]],
            ]],
        ])
        guard case .snapshot(let devices) = parsed else {
            Issue.record("expected a snapshot, got \(parsed)")
            return
        }
        #expect(devices.count == 1)
        let instances = try #require(devices.first?.instances)
        #expect(instances.map(\.tag) == ["default", "issue-8001"])
        #expect(instances[0].online)
        #expect(instances[0].displayName == "Studio")
        #expect(instances[0].routes?.map(\.id) == ["ts"])
        #expect(instances[0].instanceID == SurfaceDeviceInstanceID(deviceID: uuid, tag: "default"))
        #expect(instances[1].platform == "mac", "platform defaults to mac for older workers")
        #expect(instances[1].routes == nil)
        #expect(instances[1].online == false)
    }

    @Test("Presence edges parse to typed frames; unknown types and other collections are ignored")
    func edgesAndIgnoredFrames() throws {
        let instance: [String: Any] = ["deviceId": uuid, "tag": "default", "platform": "mac", "online": true, "lastSeenAt": 5]
        guard case .online(let online) = try frame(["type": "online", "instance": instance]) else {
            Issue.record("expected online")
            return
        }
        #expect(online.deviceId == uuid)
        guard case .offline = try frame(["type": "offline", "instance": instance]) else {
            Issue.record("expected offline")
            return
        }
        guard case .routes = try frame(["type": "routes", "instance": instance]) else {
            Issue.record("expected routes")
            return
        }
        #expect(try frame(["type": "seen", "deviceId": uuid, "tag": "default", "lastSeenAt": 42]) == .seen(deviceId: uuid, tag: "default", lastSeenAt: 42))
        #expect(try frame(["type": "online"]) == .ignored, "an edge without an instance is ignored, not fatal")
        #expect(try frame(["type": "seen", "deviceId": uuid]) == .ignored)
        #expect(try frame(["type": "hello.v9"]) == .ignored)
        #expect(try frame(["ping": true]) == .ignored)
        #expect(try frame(["type": "sync.delta", "collection": "workspaces", "records": []]) == .ignored)
        #expect(try DevicePresenceFrame.parse(Data("[1, 2]".utf8)) == .ignored)
        #expect(throws: (any Error).self) {
            try DevicePresenceFrame.parse(Data("not json".utf8))
        }
    }

    @Test("The devices sync collection yields owners; deleted records carry no device")
    func syncRecords() throws {
        let parsed = try frame([
            "type": "sync.snapshot", "collection": "devices", "complete": true,
            "records": [
                ["id": uuid, "payload": ["deviceId": uuid, "ownerUserId": "user_a", "platform": "mac"]],
                ["id": "gone", "deleted": true],
                ["id": "bare", "payload": ["deviceId": "bare"]],
                ["payload": ["deviceId": "no-id"]],
            ],
        ])
        guard case .syncSnapshot(let records, let complete) = parsed else {
            Issue.record("expected a sync snapshot, got \(parsed)")
            return
        }
        #expect(complete)
        #expect(records.map(\.id) == [uuid, "gone", "bare"])
        #expect(records[0].device?.ownerUserId == "user_a")
        #expect(records[1].deleted)
        #expect(records[1].device == nil)
        #expect(records[2].device?.ownerUserId == nil)

        let partial = try frame(["type": "sync.snapshot", "collection": "devices", "records": []])
        #expect(partial == .syncSnapshot(records: [], complete: false))
        let delta = try frame(["type": "sync.delta", "collection": "devices", "records": [["id": "x", "deleted": true]]])
        #expect(delta == .syncDelta(records: [DeviceSyncRecord(id: "x", deleted: true, device: nil)]))
    }

    @Test("sync.hello asks for the devices collection from a fresh cursor")
    func syncHello() throws {
        let raw = try JSONSerialization.jsonObject(with: DevicePresenceFrame.syncHello())
        let object = try #require(raw as? [String: Any])
        #expect(object["type"] as? String == "sync.hello")
        #expect(object["protocol"] as? String == "sync/v1")
        let collections = try #require(object["collections"] as? [[String: Any]])
        #expect(collections.count == 1)
        #expect(collections.first?["name"] as? String == "devices")
        #expect(collections.first?["cursor"] as? Int == 0)
        #expect(collections.first?["epoch"] as? Int == 0)
    }

    @Test("Registry rows decode both instance levels, manual remotes, and lenient timestamps")
    func registryParse() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "devices": [
                [
                    "deviceId": uuid, "platform": "mac", "displayName": "Studio", "lastSeenAt": "2026-09-01T10:00:00.250Z",
                    "instances": [
                        ["tag": "", "lastSeenAt": "2026-09-01T10:00:00Z", "routes": [
                            ["id": "ts", "kind": "tailscale", "endpoint": ["type": "host_port", "host": "100.64.0.9", "port": 51000], "priority": 10],
                            ["id": "future", "kind": "quantum", "endpoint": ["type": "wormhole"]],
                        ]],
                        ["tag": "issue-8001", "lastSeenAt": "garbage"],
                    ],
                ],
                ["deviceId": "manual-1", "platform": "mac", "labels": ["manual": true]],
                ["deviceId": "   ", "platform": "mac"],
                ["deviceId": "phone-1", "platform": "iOS", "displayName": ""],
            ],
        ])
        let devices = try #require(DeviceRegistryDirectoryClient.parse(data))
        #expect(devices.map(\.deviceID) == [uuid, "manual-1", "phone-1"])
        let base = try #require(ISO8601DateFormatter().date(from: "2026-09-01T10:00:00Z"))
        #expect(devices[0].displayName == "Studio")
        #expect(devices[0].lastSeenAt == base.addingTimeInterval(0.25))
        #expect(devices[0].isManual == false)
        #expect(devices[0].instances.map(\.tag) == ["default", "issue-8001"])
        #expect(devices[0].instances[0].lastSeenAt == base)
        #expect(devices[0].instances[0].routes.map(\.id) == ["ts"])
        #expect(devices[0].instances[1].lastSeenAt == nil)
        #expect(devices[0].instances[1].routes.isEmpty)
        #expect(devices[1].isManual)
        #expect(devices[1].instances.isEmpty)
        #expect(devices[2].platform == "ios")
        #expect(devices[2].displayName == nil)
        #expect(DeviceRegistryDirectoryClient.parse(Data("[]".utf8)) == nil)
        #expect(DeviceRegistryDirectoryClient.parse(Data("{}".utf8)) == nil)
    }
}
