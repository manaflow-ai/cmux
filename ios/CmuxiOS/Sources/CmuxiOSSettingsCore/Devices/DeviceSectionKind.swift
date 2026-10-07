/// The groups of the Devices & Macs list, in display order.
public enum DeviceSectionKind: String, Hashable, Sendable, CaseIterable {
    case thisDevice
    case macs
    case otherDevices
}
