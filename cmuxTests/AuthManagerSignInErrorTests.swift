import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AuthManagerSignInErrorTests: XCTestCase {
    func testInvalidCallbackStoresVisibleSignInError() async throws {
        let suiteName = "AuthManagerSignInErrorTests.InvalidCallback.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = AuthManager(
            tokenStore: TestTokenStore(),
            settingsStore: AuthSettingsStore(userDefaults: defaults)
        )
        await manager.awaitBootstrapped()

        do {
            try await manager.handleCallbackURL(URL(string: "cmux://auth-callback?stack_refresh=refresh-token")!)
            XCTFail("Expected invalid callback to throw")
        } catch AuthManagerError.invalidCallback {
            // Expected path.
        } catch {
            XCTFail("Expected invalidCallback, got \(error)")
        }

        guard case .authManager(.invalidCallback)? = manager.lastSignInError else {
            XCTFail("Expected invalid callback to be stored as the visible sign-in error")
            return
        }
        XCTAssertEqual(
            manager.lastSignInError?.localizedMessage,
            AuthManagerError.invalidCallback.errorDescription
        )
    }
}

private actor TestTokenStore: StackAuthTokenStoreProtocol {
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
