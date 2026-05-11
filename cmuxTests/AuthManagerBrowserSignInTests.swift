import XCTest
import Combine
import CMUXAuthCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AuthManagerBrowserSignInTests: XCTestCase {
    private actor InMemoryAuthTokenStore: StackAuthTokenStoreProtocol {
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

    private struct StubAuthClient: AuthClientProtocol {
        let user = CMUXAuthUser(
            id: "user_123",
            primaryEmail: "user@example.com",
            displayName: "Test User"
        )
        let teams = [AuthTeamSummary(id: "team_123", displayName: "Team")]

        func currentUser() async throws -> CMUXAuthUser? {
            user
        }

        func listTeams() async throws -> [AuthTeamSummary] {
            teams
        }
    }

    private struct FailingRefreshAuthClient: AuthClientProtocol {
        func currentUser() async throws -> CMUXAuthUser? {
            throw AuthManagerError.invalidCallback
        }

        func listTeams() async throws -> [AuthTeamSummary] {
            []
        }
    }

    private func makeIsolatedSettingsStore() -> AuthSettingsStore {
        let suiteName = "cmux-auth-manager-browser-sign-in-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AuthSettingsStore(userDefaults: defaults)
    }

    func testBeginSignInOpensExternalBrowserCallbackURL() async {
        let tokenStore = InMemoryAuthTokenStore()
        var openedURL: URL?
        let manager = AuthManager(
            client: StubAuthClient(),
            tokenStore: tokenStore,
            settingsStore: makeIsolatedSettingsStore(),
            urlOpener: { openedURL = $0 },
            usesSystemWebAuthenticationSession: { false }
        )
        await manager.awaitBootstrapped()

        var observedLoadingValues: [Bool] = []
        let loadingSink = manager.$isLoading.sink {
            observedLoadingValues.append($0)
        }

        manager.beginSignIn()
        withExtendedLifetime(loadingSink) {}

        let url = openedURL
        XCTAssertEqual(url?.path, "/handler/sign-in")
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let afterAuthReturnTo = components?.queryItems?.first { $0.name == "after_auth_return_to" }?.value
        XCTAssertEqual(url?.scheme, AuthEnvironment.afterSignInOrigin.scheme)
        XCTAssertEqual(url?.host, AuthEnvironment.afterSignInOrigin.host)
        XCTAssertTrue(afterAuthReturnTo?.contains(AuthEnvironment.callbackURL.absoluteString) == true)
        XCTAssertFalse(manager.isLoading)
        XCTAssertEqual(observedLoadingValues, [false])
        await manager.signOut()
    }

    func testBrowserCallbackClearsLoadingAndSeedsTokens() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        var openedURL: URL?
        let manager = AuthManager(
            client: StubAuthClient(),
            tokenStore: tokenStore,
            settingsStore: makeIsolatedSettingsStore(),
            urlOpener: { openedURL = $0 },
            usesSystemWebAuthenticationSession: { false }
        )
        await manager.awaitBootstrapped()

        manager.beginSignIn()
        XCTAssertNotNil(openedURL)
        XCTAssertFalse(manager.isLoading)

        let callbackURL = try XCTUnwrap(URL(
            string: "\(AuthEnvironment.callbackScheme)://auth-callback?stack_refresh=refresh-token&stack_access=access-token"
        ))
        try await manager.handleCallbackURL(callbackURL)

        XCTAssertFalse(manager.isLoading)
        XCTAssertTrue(manager.isAuthenticated)
        XCTAssertEqual(manager.currentUser?.id, "user_123")
        let storedAccessToken = await tokenStore.getStoredAccessToken()
        let storedRefreshToken = await tokenStore.getStoredRefreshToken()
        XCTAssertEqual(storedAccessToken, "access-token")
        XCTAssertEqual(storedRefreshToken, "refresh-token")
        let cachedAccessToken = try await manager.getAccessToken()
        XCTAssertEqual(cachedAccessToken, "access-token")

        await manager.signOut()
        do {
            _ = try await manager.getAccessToken()
            XCTFail("Expected sign out to clear the cached access token")
        } catch AuthManagerError.missingAccessToken {
            let storedAccessTokenAfterSignOut = await tokenStore.getStoredAccessToken()
            XCTAssertNil(storedAccessTokenAfterSignOut)
        } catch {
            XCTFail("Unexpected access token error: \(error)")
        }
    }

    func testBrowserCallbackDoesNotCacheAccessTokenWhenRefreshFails() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        let manager = AuthManager(
            client: FailingRefreshAuthClient(),
            tokenStore: tokenStore,
            settingsStore: makeIsolatedSettingsStore(),
            urlOpener: { _ in },
            usesSystemWebAuthenticationSession: { false }
        )
        await manager.awaitBootstrapped()

        let callbackURL = try XCTUnwrap(URL(
            string: "\(AuthEnvironment.callbackScheme)://auth-callback?stack_refresh=refresh-token&stack_access=access-token"
        ))

        do {
            try await manager.handleCallbackURL(callbackURL)
            XCTFail("Expected refresh failure to propagate")
        } catch AuthManagerError.invalidCallback {
            XCTAssertFalse(manager.isAuthenticated)
            XCTAssertFalse(manager.isLoading)
            do {
                _ = try await manager.getAccessToken()
                XCTFail("Expected failed callback refresh to leave the fast cache empty")
            } catch AuthManagerError.missingAccessToken {
            } catch {
                XCTFail("Unexpected access token error: \(error)")
            }
        } catch {
            XCTFail("Unexpected callback error: \(error)")
        }
    }

    func testBrowserCallbackClearsPreviousFastAccessTokenWhenRefreshFails() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        let manager = AuthManager(
            client: FailingRefreshAuthClient(),
            tokenStore: tokenStore,
            settingsStore: makeIsolatedSettingsStore(),
            urlOpener: { _ in },
            usesSystemWebAuthenticationSession: { false }
        )
        await manager.awaitBootstrapped()

        manager.applySignInResult(AuthManager.SignInResult(
            accessToken: "old-access-token",
            refreshToken: "old-refresh-token",
            email: "old@example.com",
            displayName: "Old User",
            userId: "old_user",
            selectedTeamId: nil,
            teams: []
        ))
        let previousAccessToken = try await manager.getAccessToken()
        XCTAssertEqual(previousAccessToken, "old-access-token")

        let callbackURL = try XCTUnwrap(URL(
            string: "\(AuthEnvironment.callbackScheme)://auth-callback?stack_refresh=refresh-token&stack_access=access-token"
        ))

        do {
            try await manager.handleCallbackURL(callbackURL)
            XCTFail("Expected refresh failure to propagate")
        } catch AuthManagerError.invalidCallback {
            do {
                _ = try await manager.getAccessToken()
                XCTFail("Expected failed callback refresh to clear the previous fast cache")
            } catch AuthManagerError.missingAccessToken {
            } catch {
                XCTFail("Unexpected access token error: \(error)")
            }
        } catch {
            XCTFail("Unexpected callback error: \(error)")
        }
    }
}
