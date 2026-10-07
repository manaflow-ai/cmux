/// Who this install is, as the backend names it (from `InstallIdentity.ownerInstall()`).
public struct PairingAccount: Hashable, Sendable {
    public var user: String
    public var install: String
    /// The API environment link certificates are signed for.
    public var environment: String

    public init(user: String, install: String, environment: String) {
        self.user = user
        self.install = install
        self.environment = environment
    }
}
