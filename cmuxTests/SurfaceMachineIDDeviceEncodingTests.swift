import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `SurfaceMachineID.device` rides the same string wire as `local` and cloud
/// ids (`surface.catalog`, `cmux vm tree --json`, persisted collapse state), so
/// the `device:<uuid>@<tag>` form must round-trip, never be mistaken for a cloud
/// machine, and never turn a cloud slug into a device.
@Suite("Surface machine id: device encoding")
struct SurfaceMachineIDDeviceEncodingTests {
    private let uuid = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"

    private var studio: SurfaceDeviceInstanceID {
        SurfaceDeviceInstanceID(deviceID: uuid, tag: "default")
    }

    private func machineInfo(_ id: SurfaceMachineID, linkState: SurfaceLinkState, presence: SurfaceDevicePresence?) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: id, name: "Studio", status: "running", image: nil, hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: linkState, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            remoteWorkspaces: [
                SurfaceRemoteWorkspace(id: "w1", name: "main", index: 0, focused: true, detail: "/Users/me", unreadCount: 2, isPinned: true),
            ],
            presence: presence
        )
    }

    @Test("The wire form round-trips through SurfaceMachineID")
    func wireRoundTrip() {
        let instance = SurfaceDeviceInstanceID(deviceID: uuid, tag: "issue-8001")
        let machine = SurfaceMachineID.device(instance)
        #expect(machine.rawValue == "device:\(uuid)@issue-8001")
        #expect(SurfaceMachineID(rawValue: machine.rawValue) == machine)
        #expect(machine.isDevice)
        #expect(machine.deviceInstance == instance)
        #expect(!machine.isLocal)
        #expect(machine.cloudMachineID == nil)
    }

    @Test("Device UUIDs canonicalize to lowercase and an empty tag is the default tag")
    func canonicalization() {
        let upper = SurfaceDeviceInstanceID(deviceID: uuid.uppercased(), tag: "  ")
        #expect(upper.deviceID == uuid)
        #expect(upper.tag == SurfaceDeviceInstanceID.defaultTag)
        #expect(upper.isDefaultTag)
        #expect(upper == studio)
        #expect(upper.appInstanceIdentity.instanceTag == nil)
        let tagged = SurfaceDeviceInstanceID(deviceID: uuid, tag: " issue-8001 ")
        #expect(tagged.tag == "issue-8001")
        #expect(tagged.appInstanceIdentity.instanceTag == "issue-8001")
    }

    @Test("The first @ after the prefix splits identity from tag, so tags may contain @")
    func tagMayContainSeparator() throws {
        let parsed = try #require(SurfaceDeviceInstanceID(wireValue: "device:\(uuid)@a@b"))
        #expect(parsed.deviceID == uuid)
        #expect(parsed.tag == "a@b")
    }

    @Test("Cloud slugs and local stay what they were; malformed device values never crash")
    func nonDeviceValues() {
        #expect(SurfaceMachineID(rawValue: "local") == .local)
        #expect(SurfaceMachineID(rawValue: "brave-otter") == .cloud("brave-otter"))
        #expect(SurfaceMachineID(rawValue: "brave-otter").isDevice == false)
        #expect(SurfaceDeviceInstanceID(wireValue: "device:no-separator") == nil)
        #expect(SurfaceDeviceInstanceID(wireValue: "device:@tag") == nil)
        #expect(SurfaceDeviceInstanceID(wireValue: "device:\(uuid)@") == nil)
        #expect(SurfaceDeviceInstanceID(wireValue: "cloud:\(uuid)@default") == nil)
        // The prefix without a tag falls back to the cloud case: the catalog
        // keeps listing such a row rather than dropping it.
        #expect(SurfaceMachineID(rawValue: "device:no-separator") == .cloud("device:no-separator"))
    }

    @Test("Machine info with presence encodes and decodes as JSON")
    func machineInfoJSONRoundTrip() throws {
        let presence = SurfaceDevicePresence(
            state: .offline, lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000), tag: "default",
            bundleID: "com.cmuxterm.app", accountTrust: .sameAccount
        )
        let info = machineInfo(.device(studio), linkState: .offline, presence: presence)
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(SurfaceMachineInfo.self, from: data)
        #expect(decoded == info)
        // `SurfaceMachineInfo` uses synthesized Codable for the typed catalog
        // snapshot, so its enum ID is intentionally nested. The flat wire
        // representation is owned by `surfaceMachinePayload` below.
        #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])
    }

    @Test("The socket catalog payload names the machine kind and presence")
    func socketPayload() {
        let presence = SurfaceDevicePresence(
            state: .offline, lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000), tag: "default",
            bundleID: "com.cmuxterm.app", accountTrust: .sameAccount
        )
        let device = TerminalController.surfaceMachinePayload(machineInfo(.device(studio), linkState: .offline, presence: presence))
        #expect(device["kind"] as? String == "device")
        #expect(device["local"] as? Bool == false)
        #expect(device["id"] as? String == "device:\(uuid)@default")
        let devicePresence = device["presence"] as? [String: Any]
        #expect(devicePresence?["state"] as? String == "offline")
        #expect(devicePresence?["account_trust"] as? String == "sameAccount")
        #expect(devicePresence?["tag"] as? String == "default")
        #expect(devicePresence?["bundle_id"] as? String == "com.cmuxterm.app")
        #expect((devicePresence?["last_seen_at"] as? NSNumber)?.doubleValue == 1_700_000_000)

        let cloud = TerminalController.surfaceMachinePayload(machineInfo(.cloud("brave-otter"), linkState: .connected, presence: nil))
        #expect(cloud["kind"] as? String == "cloud")
        #expect(cloud["presence"] is NSNull)
        let local = TerminalController.surfaceMachinePayload(machineInfo(.local, linkState: .notApplicable, presence: nil))
        #expect(local["kind"] as? String == "local")
        #expect(local["local"] as? Bool == true)
    }

    @Test("Build labels qualify dev, nightly, rc, and tagged instances; stable stays bare")
    func buildLabels() {
        func presence(tag: String, bundleID: String?) -> SurfaceDevicePresence {
            SurfaceDevicePresence(state: .online, lastSeenAt: nil, tag: tag, bundleID: bundleID, accountTrust: .sameAccount)
        }
        #expect(presence(tag: "default", bundleID: "com.cmuxterm.app").buildLabel == nil)
        #expect(presence(tag: "default", bundleID: "com.cmuxterm.app.nightly").buildLabel == "Nightly")
        #expect(presence(tag: "default", bundleID: "com.cmuxterm.app.rc").buildLabel == "RC")
        #expect(presence(tag: "issue-8001", bundleID: "dev.cmux.issue-8001").buildLabel == "DEV \u{00B7} issue-8001")
        #expect(presence(tag: "issue-8001", bundleID: nil).buildLabel == "issue-8001")
    }
}
