public import CmuxiOSFeatureKit
public import CmuxLink

/// The live path and RTT of each device this phone has a link to (A3's
/// `PathBadge`). Whoever holds the `CmuxLink` per host (B5 or D1) owns it;
/// devices without a live link are absent from the map.
public protocol LinkDiagnosticsSource: Sendable {
    func updates() async -> AsyncStream<[DeviceRecord.ID: PathBadge]>
}
