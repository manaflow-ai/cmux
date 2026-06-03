import CmuxMobileContract
import Foundation

// The mobile contract DTOs, MobileRouteClientError, MobileAuthenticatedRouteTransport,
// MobilePushRouteClient, and MobileWorkspaceReadRouteClient now live in CmuxMobileContract.
// AuthManager conforms to the package's AuthTokenProviding seam, and the app-side convenience
// initializers below supply the Environment + AuthManager defaults the call sites rely on.

extension AuthManager: AuthTokenProviding {
    func accessToken() async throws -> String {
        try await getAccessToken()
    }
}

extension MobileAuthenticatedRouteTransport {
    convenience init(
        baseURL: URL = URL(string: Environment.current.apiBaseURL)!,
        session: URLSession = .shared,
        authManager: AuthManager? = nil
    ) {
        self.init(
            baseURL: baseURL,
            session: session,
            tokenProvider: authManager ?? AuthManager.shared
        )
    }
}

extension MobilePushRouteClient {
    convenience init(
        baseURL: URL = URL(string: Environment.current.apiBaseURL)!,
        session: URLSession = .shared,
        authManager: AuthManager? = nil
    ) {
        self.init(
            baseURL: baseURL,
            session: session,
            tokenProvider: authManager ?? AuthManager.shared
        )
    }
}

extension MobileWorkspaceReadRouteClient {
    convenience init(
        baseURL: URL = URL(string: Environment.current.apiBaseURL)!,
        session: URLSession = .shared,
        authManager: AuthManager? = nil
    ) {
        self.init(
            baseURL: baseURL,
            session: session,
            tokenProvider: authManager ?? AuthManager.shared
        )
    }
}
