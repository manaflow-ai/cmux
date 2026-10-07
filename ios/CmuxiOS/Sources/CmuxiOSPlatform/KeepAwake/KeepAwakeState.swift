import Foundation

/// One Mac's cmux-owned power assertion, as the Mac reports it.
public struct KeepAwakeState: Hashable, Sendable {
    /// False when the Mac's cmux cannot hold the assertion (old build, policy).
    public var isSupported: Bool
    /// Nil until the Mac reports.
    public var isEnabled: Bool?

    public init(isSupported: Bool, isEnabled: Bool?) {
        self.isSupported = isSupported
        self.isEnabled = isEnabled
    }
}
