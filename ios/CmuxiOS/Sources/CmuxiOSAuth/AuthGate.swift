public import Foundation

/// The signed-in account as Home needs it.
public struct SignedInAccount: Hashable, Sendable {
    public var userID: String
    public var email: String?
    public var displayName: String

    public init(userID: String, email: String?, displayName: String) {
        self.userID = userID
        self.email = email
        self.displayName = displayName
    }
}

public enum AuthState: Hashable, Sendable {
    case restoring
    case signedOut
    case signedIn(SignedInAccount)
}

/// The seam over the kept sign-in flow. The app shows the sign-in screen
/// while `state` is `.signedOut` and Home once it is `.signedIn`.
@MainActor
public protocol AuthGate: AnyObject {
    var state: AuthState { get }
    /// Called on every state change, on the main actor.
    var onChange: ((AuthState) -> Void)? { get set }
    func signOut() async
}
