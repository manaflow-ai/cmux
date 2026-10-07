public import CmuxiOSFeatureKit
import Foundation

/// The registry snapshot as Settings lists it: this device first, then Macs
/// and Cloud machines (paired before discovered), then other phones and
/// tablets. Removed devices are hidden; names sort the way Finder sorts.
public struct DeviceListProjection: Hashable, Sendable {
    public var sections: [DeviceListSection]

    public init(devices: [DeviceRecord]) {
        let visible = devices.filter { $0.trust != .revoked }
        let this = visible.filter(\.isThisDevice)
        let others = visible.filter { !$0.isThisDevice }
        let macs = others.filter { $0.platform == .mac || $0.platform == .cloudVM }.sorted(by: Self.order)
        let rest = others.filter { $0.platform == .iPhone || $0.platform == .iPad }.sorted(by: Self.order)
        sections = [
            DeviceListSection(kind: .thisDevice, devices: this),
            DeviceListSection(kind: .macs, devices: macs),
            DeviceListSection(kind: .otherDevices, devices: rest),
        ].filter { !$0.devices.isEmpty }
    }

    private static func order(_ lhs: DeviceRecord, _ rhs: DeviceRecord) -> Bool {
        let lhsTrusted = lhs.trust == .trusted
        let rhsTrusted = rhs.trust == .trusted
        if lhsTrusted != rhsTrusted { return lhsTrusted }
        let names = lhs.name.localizedStandardCompare(rhs.name)
        if names != .orderedSame { return names == .orderedAscending }
        return lhs.id < rhs.id
    }
}
