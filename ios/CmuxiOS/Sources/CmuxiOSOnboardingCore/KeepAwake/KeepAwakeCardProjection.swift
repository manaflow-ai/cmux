public import CmuxiOSFeatureKit
import Foundation

/// The keep-awake card's rows: the account's trusted Macs (names from the
/// device registry) joined with what each Mac reports, sorted by name.
public struct KeepAwakeCardProjection: Hashable, Sendable {
    public var macs: [KeepAwakeCardMac]

    public init(devices: [DeviceRecord], reports: [HostID: KeepAwakeReport]) {
        macs = devices
            .filter { $0.platform == .mac && $0.trust == .trusted && !$0.isThisDevice }
            .compactMap { device in
                guard let host = device.hostID.map(HostID.init(rawValue:)) else { return nil }
                let availability: KeepAwakeCardMac.Availability
                switch reports[host] {
                case nil: availability = .checking
                case let report? where !report.isSupported: availability = .unavailable
                case let report?: availability = report.isEnabled.map { .available(isOn: $0) } ?? .checking
                }
                return KeepAwakeCardMac(id: host, name: device.name, availability: availability)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether any Mac can take the toggle now.
    public var hasAvailableMac: Bool {
        macs.contains { if case .available = $0.availability { true } else { false } }
    }
}
