public import CmuxiOSFeatureKit

/// Two Macs from `MockFixtures`: the first current, the second one protocol
/// version behind (shows the update gate).
public final class MockMacCapabilitiesSource: MacCapabilitiesSource {
    public let hub: MockSnapshotHub<[HostID: MacCapabilities]>

    public init(current: Int = MacCompatibilityPolicy.appProtocols.upperBound) {
        let macs = MockFixtures.hosts().filter { host in
            if case .pairedMac = host.kind { return true }
            return false
        }
        var value: [HostID: MacCapabilities] = [:]
        for (index, mac) in macs.enumerated() {
            value[mac.id] = MacCapabilities(
                host: mac.id, name: mac.name, appVersion: index == 0 ? "0.70.0" : "0.61.2",
                protocolVersion: index == 0 ? current : current - 1,
                capabilities: index == 0 ? MacCompatibilityPolicy.requiredCapabilities : []
            )
        }
        hub = MockSnapshotHub(value)
    }

    public func updates() async -> AsyncStream<SourceSnapshot<[HostID: MacCapabilities]>> {
        await hub.stream()
    }
}
