/// The account's team refuses this app version (`client.too_old` from the
/// API Worker). Home shows an update-required banner until it clears.
public struct HomeUpdateRequired: Hashable, Sendable {
    /// The team's minimum version, when the owner named it.
    public var minimumVersion: String?

    public init(minimumVersion: String?) {
        self.minimumVersion = minimumVersion
    }
}
