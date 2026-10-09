public import CmuxiOSFeatureKit
import Foundation

/// What the pair step shows: a projection of the `DeviceRegistry` snapshot
/// and the local intent, never its own copy of device state.
public enum PairingPhase: Hashable, Sendable {
    case searching
    case found([PairingCandidate])
    case pairing(PairingCandidate)
    case paired(name: String)
    case failed(message: String)
    case offline

    public init(devices: [DeviceRecord], connection: SourceConnection, intent: PairingIntent) {
        switch intent {
        case .paired(let name):
            self = .paired(name: name)
            return
        case .pairing(let candidate):
            if let device = devices.first(where: { $0.id == candidate.id }), device.trust == .trusted {
                self = .paired(name: device.name)
            } else if !connection.isLive, connection != .connecting {
                // A pending pair intent must not hide a dropped registry path.
                // Show the retryable offline state until the owner is reachable
                // again; a later snapshot still confirms the same intent.
                self = .offline
            } else {
                self = .pairing(candidate)
            }
            return
        case .failed(let message):
            self = .failed(message: message)
            return
        case .idle:
            break
        }
        guard connection.isLive else {
            self = connection == .connecting ? .searching : .offline
            return
        }
        let candidates = Self.candidates(in: devices)
        self = candidates.isEmpty ? .searching : .found(candidates)
    }

    /// Same-account Macs discovered but not yet trusted.
    public static func candidates(in devices: [DeviceRecord]) -> [PairingCandidate] {
        devices
            .filter { $0.platform == .mac && $0.trust == .discovered && !$0.isThisDevice }
            .map { PairingCandidate(id: $0.id, name: $0.name) }
    }

    /// A Mac other than this device is already trusted.
    public static func hasTrustedMac(in devices: [DeviceRecord]) -> Bool {
        devices.contains { $0.platform == .mac && $0.trust == .trusted && !$0.isThisDevice }
    }

    public var isSettled: Bool {
        if case .paired = self { return true }
        return false
    }
}
