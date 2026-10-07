/// What the app may show (deferred sign-in, e5-extras.md section 5).
public enum AccessLevel: Hashable, Sendable {
    /// The stored session is restoring.
    case restoring
    /// Signed out and not using SSH without an account: the sign-in screen.
    case signIn
    /// Signed out by choice: Hosts and Settings, all on this device.
    case guest
    /// Signed in: everything.
    case account

    /// Signed in always wins; a stored guest choice applies only signed out.
    public init(isRestoring: Bool, isSignedIn: Bool, isGuest: Bool) {
        if isSignedIn {
            self = .account
        } else if isRestoring {
            self = .restoring
        } else {
            self = isGuest ? .guest : .signIn
        }
    }
}
