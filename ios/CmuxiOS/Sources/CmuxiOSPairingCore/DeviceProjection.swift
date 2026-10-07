public import CmuxiOSFeatureKit
public import CmuxPairing
public import Foundation

/// Projects the trust store mirror and host presence into the device list
/// (b6-pairing.md section 5). Pure: the same inputs give the same list.
///
/// - This account's Macs are `.discovered` until this install has published
///   its own `direct` cert (the Connect intent), then `.trusted`.
/// - Other accounts' hosts this device was accepted on are `.trusted` Macs.
/// - Guests on this account's Macs are `.trusted`; pending requests are `.discovered`
///   with their device platform (never `.mac`, so onboarding does not offer them).
public struct DeviceProjection: Sendable {
    public var account: PairingAccount

    public init(account: PairingAccount) { self.account = account }

    public func records(state: TrustStoreState, presence: [String: HostPresence], now: Date) -> [DeviceRecord] {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        let selfPublished = state.devices[account.install]?.certs.direct.map { $0.expiresAt > nowMillis } ?? false
        var out: [DeviceRecord] = []
        for device in state.devices.values {
            let isThis = device.install == account.install
            let platform = Self.platform(kind: device.kind, platform: device.platform)
            let trust: DeviceTrust = isThis || platform != .mac || selfPublished ? .trusted : .discovered
            out.append(DeviceRecord(id: DeviceRecordID.install(device.install).rawValue, name: device.name, platform: platform,
                                    trust: trust, isThisDevice: isThis, lastSeen: Self.seen(device.host, presence, fallback: device.updatedAt)))
        }
        if state.devices[account.install] == nil {
            // This install before its first publish: still listed as this device.
            out.append(DeviceRecord(id: DeviceRecordID.install(account.install).rawValue, name: PairingText.thisDevice,
                                    platform: .iPhone, trust: .trusted, isThisDevice: true))
        }
        for entry in state.remote.values where entry.install == account.install {
            out.append(DeviceRecord(id: DeviceRecordID.remote(host: entry.host, install: entry.install).rawValue, name: entry.name,
                                    platform: .mac, trust: .trusted, lastSeen: Self.seen(entry.host, presence, fallback: entry.acceptedAt)))
        }
        for guest in state.guests.values {
            out.append(DeviceRecord(id: DeviceRecordID.guest(host: guest.host, install: guest.device.install).rawValue,
                                    name: PairingText.guestName(device: guest.device.name, user: guest.device.userName),
                                    platform: Self.platform(kind: "", platform: guest.device.platform), trust: .trusted,
                                    lastSeen: Date(timeIntervalSince1970: TimeInterval(guest.acceptedAt) / 1000)))
        }
        for request in state.requests.values where request.expiresAt > nowMillis {
            let platform = Self.platform(kind: "", platform: request.device.platform)
            out.append(DeviceRecord(id: DeviceRecordID.request(offerID: request.offerID).rawValue,
                                    name: PairingText.guestName(device: request.device.name, user: request.device.userName),
                                    platform: platform == .mac ? .iPhone : platform, trust: .discovered,
                                    lastSeen: Date(timeIntervalSince1970: TimeInterval(request.at) / 1000)))
        }
        return out.sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
    }

    /// Hosts whose presence the list shows (host id -> team; empty means the
    /// account's own team), for `HostPresenceSource`.
    public func hosts(state: TrustStoreState, team: String?) -> [String: String] {
        var out: [String: String] = [:]
        for device in state.devices.values { if let host = device.host { out[host] = team ?? "" } }
        for entry in state.remote.values where entry.install == account.install { out[entry.host] = entry.team }
        return out
    }

    static func platform(kind: String, platform: String) -> DevicePlatform {
        switch (kind, platform.lowercased()) {
        case ("mac", _), (_, "macos"), (_, "mac"), (_, "darwin"): .mac
        case ("vm", _), (_, "linux"): .cloudVM
        case (_, "ipados"), (_, "ipad"): .iPad
        default: .iPhone
        }
    }

    private static func seen(_ host: String?, _ presence: [String: HostPresence], fallback: Int64) -> Date {
        if let host, let p = presence[host] { return p.at }
        return Date(timeIntervalSince1970: TimeInterval(fallback) / 1000)
    }
}
