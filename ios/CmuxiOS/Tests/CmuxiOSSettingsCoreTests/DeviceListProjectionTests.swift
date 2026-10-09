import CmuxiOSFeatureKit
import CmuxiOSSettingsCore
import Testing

@Suite struct DeviceListProjectionTests {
    private func device(_ id: String, _ name: String, _ platform: DevicePlatform, _ trust: DeviceTrust,
                        this: Bool = false) -> DeviceRecord {
        DeviceRecord(id: id, name: name, platform: platform, trust: trust, isThisDevice: this)
    }

    @Test func sectionsInOrderWithRevokedHidden() {
        let projection = DeviceListProjection(devices: [
            device("m2", "mac 10", .mac, .trusted),
            device("p1", "iPad", .iPad, .trusted),
            device("me", "My iPhone", .iPhone, .trusted, this: true),
            device("m3", "Old Mac", .mac, .revoked),
            device("m1", "Mac 9", .mac, .trusted),
            device("m4", "Air", .mac, .discovered),
            device("vm", "Cloud box", .cloudVM, .trusted),
        ])
        #expect(projection.sections.map(\.kind) == [.thisDevice, .macs, .otherDevices])
        #expect(projection.sections[0].devices.map(\.id) == ["me"])
        // Paired first, numeric-aware names; discovered last.
        #expect(projection.sections[1].devices.map(\.id) == ["vm", "m1", "m2", "m4"])
        #expect(projection.sections[2].devices.map(\.id) == ["p1"])
    }

    @Test func emptySectionsAreDropped() {
        let projection = DeviceListProjection(devices: [device("m1", "Mac", .mac, .trusted)])
        #expect(projection.sections.map(\.kind) == [.macs])
        #expect(DeviceListProjection(devices: []).sections.isEmpty)
    }

    @Test func nameRule() throws {
        let rule = DeviceNameRule(maximumLength: 8)
        #expect(try rule.validate("  Studio \n").get() == "Studio")
        #expect(rule.validate("   ") == .failure(DeviceNameError(problem: .empty)))
        #expect(rule.validate("Mac\u{0007}") == .failure(DeviceNameError(problem: .controlCharacters)))
        #expect(rule.validate("A very long name") == .failure(DeviceNameError(problem: .tooLong(limit: 8))))
    }
}
