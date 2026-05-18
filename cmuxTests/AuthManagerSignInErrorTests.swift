import CMUXAuthCore
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

        manager.markBrowserSignInLoadingForTesting()
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
        XCTAssertNotEqual(
            manager.lastSignInError?.localizedMessage,
            AuthManagerError.invalidCallback.errorDescription
        )
        XCTAssertEqual(
            manager.lastSignInError?.localizedMessage,
            AuthSignInError.message("diagnostic detail").localizedMessage
        )
    }

    func testStaleInvalidCallbackDoesNotStoreVisibleSignInError() async throws {
        let suiteName = "AuthManagerSignInErrorTests.StaleInvalidCallback.\(UUID().uuidString)"
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

        XCTAssertNil(manager.lastSignInError)
    }

    func testApplySignInResultDoesNotRestoreAuthAfterConcurrentSignOut() async throws {
        let suiteName = "AuthManagerSignInErrorTests.ConcurrentSignOut.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tokenStore = BlockingSetTokenStore()
        let manager = AuthManager(
            client: TestAuthClient(),
            tokenStore: tokenStore,
            settingsStore: AuthSettingsStore(userDefaults: defaults)
        )
        await manager.awaitBootstrapped()

        let result = AuthManager.SignInResult(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            email: "user@example.com",
            displayName: "Test User",
            userId: "user-id",
            selectedTeamId: nil,
            teams: []
        )
        let applyTask = Task {
            await manager.applySignInResult(result)
        }

        await tokenStore.waitForBlockedSet()
        await manager.signOut()
        await tokenStore.releaseBlockedSet()
        await applyTask.value

        XCTAssertFalse(manager.isAuthenticated)
        XCTAssertNil(manager.currentUser)
        let storedAccessToken = await tokenStore.currentAccessToken()
        let storedRefreshToken = await tokenStore.currentRefreshToken()
        XCTAssertNil(storedAccessToken)
        XCTAssertNil(storedRefreshToken)
    }

    func testStaleCallbackFailureDoesNotOverwriteSignOutState() async throws {
        let suiteName = "AuthManagerSignInErrorTests.StaleCallbackFailure.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let client = BlockingFailureAuthClient()
        let manager = AuthManager(
            client: client,
            tokenStore: TestTokenStore(),
            settingsStore: AuthSettingsStore(userDefaults: defaults)
        )
        await manager.awaitBootstrapped()

        let callbackURL = try XCTUnwrap(URL(string: "cmux://auth-callback?stack_refresh=refresh-token&stack_access=access-token"))
        let callbackTask = Task {
            try await manager.handleCallbackURL(callbackURL)
        }

        await client.waitForCurrentUserRequest()
        await manager.signOut()
        await client.failCurrentUserRequest()
        try await callbackTask.value

        XCTAssertFalse(manager.isAuthenticated)
        XCTAssertNil(manager.currentUser)
        XCTAssertNil(manager.lastSignInError)
    }
}

private struct TestAuthClient: AuthClientProtocol {
    func currentUser() async throws -> CMUXAuthUser? { nil }
    func listTeams() async throws -> [AuthTeamSummary] { [] }
    func currentAccessToken() async throws -> String? { nil }
    func signOut() async throws {}
}

private actor BlockingFailureAuthClient: AuthClientProtocol {
    private var currentUserContinuation: CheckedContinuation<CMUXAuthUser?, any Error>?
    private var currentUserWaiter: CheckedContinuation<Void, Never>?

    func currentUser() async throws -> CMUXAuthUser? {
        try await withCheckedThrowingContinuation { continuation in
            currentUserContinuation = continuation
            currentUserWaiter?.resume()
            currentUserWaiter = nil
        }
    }

    func waitForCurrentUserRequest() async {
        if currentUserContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            currentUserWaiter = continuation
        }
    }

    func failCurrentUserRequest() {
        let continuation = currentUserContinuation
        currentUserContinuation = nil
        continuation?.resume(throwing: AuthManagerError.missingAccessToken)
    }

    func listTeams() async throws -> [AuthTeamSummary] { [] }
    func currentAccessToken() async throws -> String? { nil }
    func signOut() async throws {}
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

private actor BlockingSetTokenStore: StackAuthTokenStoreProtocol {
    private var accessToken: String?
    private var refreshToken: String?
    private var shouldBlockNextSet = true
    private var setIsBlocked = false
    private var setStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseSetContinuation: CheckedContinuation<Void, Never>?

    func waitForBlockedSet() async {
        if setIsBlocked { return }
        await withCheckedContinuation { continuation in
            setStartedWaiters.append(continuation)
        }
    }

    func releaseBlockedSet() {
        guard let continuation = releaseSetContinuation else { return }
        releaseSetContinuation = nil
        continuation.resume()
    }

    func getStoredAccessToken() async -> String? {
        accessToken
    }

    func getStoredRefreshToken() async -> String? {
        refreshToken
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        if shouldBlockNextSet {
            shouldBlockNextSet = false
            setIsBlocked = true
            let waiters = setStartedWaiters
            setStartedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                releaseSetContinuation = continuation
            }
            setIsBlocked = false
        }
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
