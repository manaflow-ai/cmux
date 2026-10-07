public import CmuxiOSFeatureKit
public import CmuxMobileLink

/// No carrier is wired yet: every Mac reads as unreachable, which is the truth.
@MainActor
public final class UnavailableMobileLinkDirectory: MobileLinkDirectory {
    public init() {}

    public func client(for host: HostID) -> MobileLinkClient? { nil }
}
