// Only the credential-free identity dependency is needed by the standalone
// recorder test. No authentication client, keychain, or network is linked.
public struct AuthenticatedSessionIdentity: Sendable, Equatable {
    public let generation: UInt64
    public let accountID: String

    public init(generation: UInt64, accountID: String) {
        self.generation = generation
        self.accountID = accountID
    }
}
