#if canImport(AuthenticationServices) && !os(watchOS)
import AuthenticationServices
import Foundation
import StackAuth

/// The AuthenticationServices ``StackInteractiveAuthenticator``:
/// `ASWebAuthenticationSession` for web OAuth, `ASAuthorizationController`
/// for native Apple Sign In.
public final class StackAppleInteractiveAuthenticator: StackInteractiveAuthenticator, @unchecked Sendable {
    // Read only on the main actor, by the start methods.
    private let presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?

    /// - Parameter presentationContextProvider: Anchors the browser session;
    ///   when it also conforms to `ASAuthorizationControllerPresentationContextProviding`,
    ///   it anchors the Apple Sign In sheet too.
    public init(presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? = nil) {
        self.presentationContextProvider = presentationContextProvider
    }

    @MainActor
    public func startWebAuthentication(
        url: URL,
        callbackScheme: String,
        prefersEphemeralSession: Bool,
        completion: @escaping @Sendable (URL?, StackSystemAuthError?) -> Void
    ) -> (any StackInteractiveAuthSession)? {
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackScheme
        ) { @Sendable callbackUrl, error in
            // The session does not reliably call back on the main thread
            // (macOS delivers its cancel on an XPC queue); the authenticator
            // contract promises main.
            let systemError = error.map { StackSystemAuthError($0) }
            deliverOnMain { completion(callbackUrl, systemError) }
        }
        session.prefersEphemeralWebBrowserSession = prefersEphemeralSession

        #if os(iOS) || os(macOS)
        if let provider = presentationContextProvider {
            session.presentationContextProvider = provider
        }
        #endif

        guard session.start() else { return nil }
        return WebAuthenticationSession(session)
    }

    @MainActor
    public func startAppleSignIn(
        completion: @escaping @Sendable (StackAppleSignInResult) -> Void
    ) -> any StackInteractiveAuthSession {
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let authController = ASAuthorizationController(authorizationRequests: [request])
        #if os(iOS) || os(macOS)
        if let provider = presentationContextProvider as? ASAuthorizationControllerPresentationContextProviding {
            authController.presentationContextProvider = provider
        }
        #endif

        let sessionId = UUID()
        let delegate = AppleSignInDelegate(resume: completion, onFinish: {
            Task { @MainActor in
                AppleSignInSessionStore.shared.remove(sessionId)
            }
        })
        authController.delegate = delegate

        // Keep delegate alive during the authorization
        objc_setAssociatedObject(authController, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        let session = AppleSignInSession(id: sessionId, controller: authController, delegate: delegate)
        AppleSignInSessionStore.shared.add(session)

        authController.performRequests()
        return session
    }
}

extension StackClientApp {
    /// Sign in with OAuth using ASWebAuthenticationSession (or native Apple Sign In for "apple" provider)
    /// - Parameters:
    ///   - provider: The OAuth provider ID (e.g., "google", "github", "apple")
    ///   - presentationContextProvider: Context provider for presenting the auth UI
    @MainActor
    public func signInWithOAuth(
        provider: String,
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding? = nil
    ) async throws {
        try await signInWithOAuth(
            provider: provider,
            authenticator: StackAppleInteractiveAuthenticator(presentationContextProvider: presentationContextProvider)
        )
    }
}

private final class WebAuthenticationSession: StackInteractiveAuthSession {
    private let session: ASWebAuthenticationSession

    init(_ session: ASWebAuthenticationSession) {
        self.session = session
    }

    @MainActor
    func cancel() {
        session.cancel()
    }
}

/// Runs `body` now when on the main thread, else on the main queue.
private func deliverOnMain(_ body: @escaping @Sendable () -> Void) {
    if Thread.isMainThread {
        body()
    } else {
        DispatchQueue.main.async(execute: body)
    }
}

// MARK: - Apple Sign In Delegate

/// Bridges the ASAuthorizationController delegate to a one-shot completion.
private class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate {
    private let resumeOnce: @Sendable (StackAppleSignInResult) -> Void
    private let onFinish: () -> Void

    init(
        resume: @escaping @Sendable (StackAppleSignInResult) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.resumeOnce = resume
        self.onFinish = onFinish
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            onFinish()
            let resumeOnce = self.resumeOnce
            deliverOnMain { resumeOnce(.unexpectedCredential) }
            return
        }
        onFinish()
        let resumeOnce = self.resumeOnce
        let identityToken = credential.identityToken
        deliverOnMain { resumeOnce(.credential(identityToken: identityToken)) }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        onFinish()
        let resumeOnce = self.resumeOnce
        let systemError = StackSystemAuthError(error)
        deliverOnMain { resumeOnce(.failure(systemError)) }
    }
}

@MainActor
private final class AppleSignInSessionStore {
    static let shared = AppleSignInSessionStore()
    private var sessions: [UUID: AppleSignInSession] = [:]

    func add(_ session: AppleSignInSession) {
        sessions[session.id] = session
    }

    func remove(_ id: UUID) {
        sessions[id] = nil
    }
}

private final class AppleSignInSession: StackInteractiveAuthSession {
    let id: UUID
    let controller: ASAuthorizationController
    let delegate: AppleSignInDelegate

    init(id: UUID, controller: ASAuthorizationController, delegate: AppleSignInDelegate) {
        self.id = id
        self.controller = controller
        self.delegate = delegate
    }

    /// Cancel the pending authorization request (dismissing its system UI when
    /// the OS supports it) and drop the session. Used when the awaiting task is
    /// cancelled so the sheet does not outlive the flow.
    @MainActor
    func cancel() {
        AppleSignInSessionStore.shared.remove(id)
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, visionOS 1.0, *) {
            controller.cancel()
        }
    }
}
#endif
