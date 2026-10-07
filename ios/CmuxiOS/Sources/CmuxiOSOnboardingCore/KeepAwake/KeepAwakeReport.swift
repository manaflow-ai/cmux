/// What one Mac reports about its power assertion (mirrors the platform
/// `KeepAwakeState` without importing it).
public struct KeepAwakeReport: Hashable, Sendable {
    public var isSupported: Bool
    public var isEnabled: Bool?

    public init(isSupported: Bool, isEnabled: Bool?) {
        self.isSupported = isSupported
        self.isEnabled = isEnabled
    }
}
