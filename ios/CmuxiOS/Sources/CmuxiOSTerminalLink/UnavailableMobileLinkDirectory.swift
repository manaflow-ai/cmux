public import CmuxiOSFeatureKit
public import CmuxMobileLink

/// No account (signed out, no API origin): every Mac reads as unreachable,
/// which is the truth.
@MainActor
public final class UnavailableMobileLinkDirectory: MobileLinkDirectory {
    public init() {}

    public func client(for host: HostID) async -> MobileLinkClient? { nil }
}
