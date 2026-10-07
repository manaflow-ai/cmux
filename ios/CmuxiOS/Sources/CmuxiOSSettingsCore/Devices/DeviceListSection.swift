public import CmuxiOSFeatureKit

/// One group of the Devices & Macs list.
public struct DeviceListSection: Identifiable, Hashable, Sendable {
    public var kind: DeviceSectionKind
    public var devices: [DeviceRecord]

    public var id: DeviceSectionKind { kind }

    public init(kind: DeviceSectionKind, devices: [DeviceRecord]) {
        self.kind = kind
        self.devices = devices
    }
}
