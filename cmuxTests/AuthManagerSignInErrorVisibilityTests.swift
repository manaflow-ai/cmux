import CMUXAuthCore
import StackAuth
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #3617: failed sign-in callbacks were silently
/// `NSLog`-ed and never surfaced to the UI. The fix exposes the failure as a
/// published `lastSignInError`. Per AGENTS.md regression test policy this
/// failing test ships in its own commit so CI proves it catches the bug.
@MainActor
final class AuthManagerSignInErrorVisibilityTests: XCTestCase {
    func testInvalidCallbackURLPublishesLastSignInError() async throws {
        let manager = AuthManager(
            client: NoopAuthTestClient(),
            tokenStore: InMemoryTestTokenStore()
        )
        await manager.awaitBootstrapped()

        XCTAssertNil(
            manager.lastSignInError,
            "AuthManager should not surface an error before any sign-in attempt"
        )

        // No `stack_refresh` / `stack_access` query items: this is the exact
        // shape that makes `AuthCallbackRouter.callbackPayload` return nil and
        // forces `handleCallbackURL` to throw `.invalidCallback`. Do not
        // "fix" the URL — that would defeat this regression.
        let badCallbackURL = URL(string: "cmux://auth-callback")!

        do {
            try await manager.handleCallbackURL(badCallbackURL)
            XCTFail("Expected handleCallbackURL to throw AuthManagerError.invalidCallback")
        } catch AuthManagerError.invalidCallback {
        } catch let error as AuthManagerError {
            XCTFail("Expected .invalidCallback, got AuthManagerError.\(error)")
        } catch {
            XCTFail("Expected AuthManagerError, got \(type(of: error)): \(error)")
        }

        XCTAssertEqual(
            manager.lastSignInError,
            AuthManagerError.invalidCallback,
            "After a failed sign-in callback, AuthManager.lastSignInError must be populated so AuthSettingsRow can render it"
        )
    }

    func testSignOutClearsStaleLastSignInError() async throws {
        let manager = AuthManager(
            client: NoopAuthTestClient(),
            tokenStore: InMemoryTestTokenStore()
        )
        await manager.awaitBootstrapped()

        // Stale-error invariant: a prior failed sign-in leaves .invalidCallback
        // published; signOut → clearSessionState must clear it.
        do {
            try await manager.handleCallbackURL(URL(string: "cmux://auth-callback")!)
            XCTFail("Expected handleCallbackURL to throw")
        } catch {
        }
        XCTAssertEqual(manager.lastSignInError, .invalidCallback)

        await manager.signOut()

        XCTAssertNil(
            manager.lastSignInError,
            "signOut() routes through clearSessionState which must clear lastSignInError so it doesn't survive across auth-state transitions"
        )
    }
}

// MARK: - Test doubles

private final class NoopAuthTestClient: AuthClientProtocol {
    func currentUser() async throws -> CMUXAuthUser? { nil }
    func listTeams() async throws -> [AuthTeamSummary] { [] }
}

private final actor InMemoryTestTokenStore: StackAuthTokenStoreProtocol {
    private var accessToken: String?
    private var refreshToken: String?

    func getStoredAccessToken() async -> String? { accessToken }
    func getStoredRefreshToken() async -> String? { refreshToken }

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
        if refreshToken == compareRefreshToken {
            refreshToken = newRefreshToken
            accessToken = newAccessToken
        }
    }
}
