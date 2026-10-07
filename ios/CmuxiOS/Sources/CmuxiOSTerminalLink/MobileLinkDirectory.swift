public import CmuxiOSFeatureKit
public import CmuxMobileLink

/// The phone's `cmux.mobile/1` session per paired Mac. Carrier lanes (B2
/// WebRTC, B4 direct address) fill it with a `MobileLinkClient` over their
/// `LinkCarrier` and the device's paired key; nil means no carrier reaches
/// that Mac.
@MainActor
public protocol MobileLinkDirectory: AnyObject {
    func client(for host: HostID) -> MobileLinkClient?
}
