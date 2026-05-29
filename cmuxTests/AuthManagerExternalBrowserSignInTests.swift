import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct AuthManagerExternalBrowserSignInTests {
    @Test
    func beginSignInOpensSignInURLThroughInjectedBrowserOpener() async throws {
        let suiteName = "AuthManagerExternalBrowserSignInTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var openedURL: URL?
        let manager = AuthManager(
            client: AuthManagerExternalBrowserSignInTestClient(),
            tokenStore: AuthManagerExternalBrowserSignInTestTokenStore(),
            settingsStore: AuthSettingsStore(userDefaults: defaults),
            urlOpener: { url in
                openedURL = url
            }
        )
        await manager.awaitBootstrapped()

        manager.beginSignIn()
        let isLoadingAfterBegin = manager.isLoading
        await manager.signOut()

        let url = try #require(openedURL)
        #expect(url.path == "/handler/sign-in")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let afterAuthReturnTo = try #require(
            components.queryItems?.first { $0.name == "after_auth_return_to" }?.value
        )
        #expect(afterAuthReturnTo.contains("native_app_return_to="))
        #expect(afterAuthReturnTo.contains("auth-callback"))
        #expect(afterAuthReturnTo.contains("state="))
        #expect(isLoadingAfterBegin)
    }
}

private struct AuthManagerExternalBrowserSignInTestClient: AuthClientProtocol {
    func currentUser() async throws -> CMUXAuthUser? { nil }
    func listTeams() async throws -> [AuthTeamSummary] { [] }
    func currentAccessToken() async throws -> String? { nil }
    func signOut() async throws {}
}

private actor AuthManagerExternalBrowserSignInTestTokenStore: StackAuthTokenStoreProtocol {
    private var accessToken: String?
    private var refreshToken: String?

    func getStoredAccessToken() async -> String? {
        accessToken
    }

    func getStoredRefreshToken() async -> String? {
        refreshToken
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    func clearTokens() async {
        accessToken = nil
        refreshToken = nil
    }

    func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        guard refreshToken == compareRefreshToken else { return }
        refreshToken = newRefreshToken
        accessToken = newAccessToken
    }
}
