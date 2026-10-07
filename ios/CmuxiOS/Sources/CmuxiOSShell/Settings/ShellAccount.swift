import Foundation

/// The signed-in account as Settings shows it.
public struct ShellAccount: Hashable, Sendable {
    public var displayName: String
    public var email: String?

    public init(displayName: String, email: String?) {
        self.displayName = displayName
        self.email = email
    }
}
