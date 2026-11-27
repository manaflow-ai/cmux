import Foundation

/// Presents the system UI behind ``StackClientApp/signInWithOAuth(provider:authenticator:)``:
/// a web authentication session and native Apple Sign In.
///
/// StackAuth itself never imports AuthenticationServices; an app that links
/// it gets that framework only through an authenticator.
/// `StackAppleInteractiveAuthenticator` (product `StackAuthAppleUI`) wraps
/// `ASWebAuthenticationSession` and `ASAuthorizationController`; an app can
/// instead forward to a framework it loads lazily.
///
/// Both methods run on the main actor, and every completion must run on the
/// main thread, at most once.
public protocol StackInteractiveAuthenticator: Sendable {
    /// Starts a browser session at `url` that finishes on a redirect to
    /// `callbackScheme`.
    /// - Returns: The running session, or nil when it would not start;
    ///   `completion` then never runs.
    @MainActor
    func startWebAuthentication(
        url: URL,
        callbackScheme: String,
        prefersEphemeralSession: Bool,
        completion: @escaping @Sendable (URL?, StackSystemAuthError?) -> Void
    ) -> (any StackInteractiveAuthSession)?

    /// Starts Sign in with Apple with the full name and email scopes.
    @MainActor
    func startAppleSignIn(
        completion: @escaping @Sendable (StackAppleSignInResult) -> Void
    ) -> any StackInteractiveAuthSession
}

/// A running system flow from a ``StackInteractiveAuthenticator``.
public protocol StackInteractiveAuthSession: AnyObject {
    /// Dismisses the flow's system UI. Its completion may still run.
    @MainActor
    func cancel()
}

/// How a Sign in with Apple request ended.
public enum StackAppleSignInResult: Sendable, Equatable {
    /// An Apple ID credential, with its identity token if it has one.
    case credential(identityToken: Data?)
    /// Apple returned a credential that is not an Apple ID credential.
    case unexpectedCredential
    /// The request failed with this system error.
    case failure(StackSystemAuthError)
}

/// A system error from an interactive auth flow, by its `NSError` domain and
/// code, so StackAuth can map it without importing the framework that raised
/// it.
public struct StackSystemAuthError: Sendable, Equatable {
    public let domain: String
    public let code: Int
    /// The error's `localizedDescription`.
    public let message: String

    public init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }

    /// Captures `error`'s domain, code and `localizedDescription`.
    public init(_ error: any Error) {
        let nsError = error as NSError
        self.init(domain: nsError.domain, code: nsError.code, message: error.localizedDescription)
    }
}

extension StackSystemAuthError {
    /// `ASWebAuthenticationSessionError.canceledLogin`. Matched by code only,
    /// as StackAuth always has.
    static let webAuthenticationCanceledLoginCode = 1

    /// `ASAuthorizationError.errorDomain`.
    static let authorizationErrorDomain = "com.apple.AuthenticationServices.AuthorizationError"

    /// The error ``StackClientApp/signInWithOAuth(provider:authenticator:)``
    /// throws when its web authentication session fails.
    var webAuthenticationFailure: any Error {
        if code == Self.webAuthenticationCanceledLoginCode {
            return StackAuthError(code: "oauth_cancelled", message: "User cancelled OAuth")
        }
        return OAuthError(code: "oauth_error", message: message)
    }

    /// The error ``StackClientApp/signInWithOAuth(provider:authenticator:)``
    /// throws when Sign in with Apple fails, by `ASAuthorizationError.Code`.
    var appleSignInFailure: any Error {
        guard domain == Self.authorizationErrorDomain else {
            // Non-ASAuthorizationError (rare)
            return OAuthError(code: "oauth_error", message: message)
        }
        switch code {
        case 1001:
            // .canceled: the person tapped Cancel or dismissed the Sign In
            // with Apple dialog.
            return StackAuthError(code: "oauth_cancelled", message: "User cancelled Apple Sign In")

        case 1000:
            // .unknown: the app is not properly configured for Sign In with
            // Apple. This is the most common error during development.
            return StackAuthError(
                code: "apple_signin_not_configured",
                message: "Apple Sign In is not configured correctly (error 1000). " +
                         "To fix this: " +
                         "(1) Open your project in Xcode, go to Signing & Capabilities, and add 'Sign In with Apple'. " +
                         "(2) Ensure the app is signed with a valid Apple Developer certificate (not just a personal team). " +
                         "(3) Register your Bundle ID at developer.apple.com and enable Sign In with Apple for it."
            )

        case 1002:
            // .invalidResponse: Apple's servers returned an unexpected or
            // malformed response. Usually a temporary server-side issue.
            return StackAuthError(
                code: "apple_signin_invalid_response",
                message: "Apple's servers returned an unexpected response. This is usually temporary - please try again in a moment."
            )

        case 1003:
            // .notHandled: no authorization provider could handle this
            // request. This can happen if Apple ID is not set up on the device.
            return StackAuthError(
                code: "apple_signin_not_handled",
                message: "Apple Sign In could not be completed. Ensure you are signed in to an Apple ID on this device (Settings > Apple ID)."
            )

        case 1004:
            // .failed: authentication failed (network issues, Apple ID
            // issues, etc.).
            return StackAuthError(
                code: "apple_signin_failed",
                message: "Apple Sign In authentication failed. Check your internet connection and ensure your Apple ID is working correctly."
            )

        case 1005:
            // .notInteractive: a silent sign-in needed the person. This
            // shouldn't happen since the dialog is always shown.
            return StackAuthError(
                code: "apple_signin_not_interactive",
                message: "Apple Sign In requires user interaction. Please try signing in again."
            )

        default:
            return StackAuthError(
                code: "apple_signin_error",
                message: "Apple Sign In failed with error code \(code): \(message)"
            )
        }
    }
}
