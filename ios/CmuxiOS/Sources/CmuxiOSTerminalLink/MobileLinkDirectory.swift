public import CmuxiOSFeatureKit
public import CmuxMobileLink

/// The phone's `cmux.mobile/1` session per paired Mac (d1-terminal-ux.md
/// section 2). `AccountLinkDirectory` holds one `MobileLinkClient` per
/// reachable Mac over B4/B2/B3 carriers; terminals and file transfers share
/// it. `client(for:)` waits briefly for the account's trust store to name
/// the Mac (the first snapshot after sign-in), then nil means no carrier
/// reaches that Mac.
@MainActor
public protocol MobileLinkDirectory: AnyObject {
    func client(for host: HostID) async -> MobileLinkClient?
}
