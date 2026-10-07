import Foundation

/// The distribution channel of this build, for What's New audiences.
public enum BuildChannel: String, Sendable, CaseIterable {
    /// DEBUG and tagged dev builds.
    case dev
    /// TestFlight beta (`dev.cmux.app.beta`).
    case beta
    /// The App Store app.
    case appStore

    /// The channel for a bundle id; DEBUG builds are always dev.
    public init(bundleID: String, isDebug: Bool) {
        if isDebug || bundleID.hasPrefix("dev.cmux.ios.") {
            self = .dev
        } else if bundleID == "dev.cmux.app.beta" {
            self = .beta
        } else {
            self = .appStore
        }
    }
}
