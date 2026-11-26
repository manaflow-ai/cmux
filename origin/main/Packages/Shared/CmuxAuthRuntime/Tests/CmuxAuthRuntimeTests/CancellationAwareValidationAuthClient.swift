import CMUXAuthCore
import Foundation
@testable import CmuxAuthRuntime

actor CancellationAwareValidationAuthClient: AuthClient {
    private let user: CMUXAuthUser
    private var access: String? = "old-access"
    private var refresh: String? = "old-refresh"
    private var validationStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var validationHasStarted = false
    private var validationShouldWaitForCancellation = true
    private var validationCancellationObserved = false
    private(set) var oldSessionRefreshProbeCount = 0

    init(user: CMUXAuthUser) {
        self.user = user
    }

    func validationDidStart() async {
        if validationHasStarted { return }
        await withCheckedContinuation { validationStartedWaiters.append($0) }
    }

    func accessToken() async -> String? { access }

    func refreshToken() async -> String? {
        if validationCancellationObserved, refresh == "old-refresh" {
            oldSessionRefreshProbeCount += 1
        }
        return refresh
    }

    func forceRefreshAccessToken() async -> String? { access }

    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        if validationShouldWaitForCancellation {
            validationShouldWaitForCancellation = false
            validationHasStarted = true
            let waiters = validationStartedWaiters
            validationStartedWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
            while !Task.isCancelled {
                await Task.yield()
            }
            validationCancellationObserved = true
            throw CancellationError()
        }
        return user
    }

    func listTeams() async throws -> [CMUXAuthTeam] { [] }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "nonce" }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {
        access = "new-access"
        refresh = "new-refresh"
    }
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}
    func storedAccessToken() async -> String? { access }

    func clearLocalSession() async {
        access = nil
        refresh = nil
    }

    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {
        guard self.refresh == refreshToken else { return }
        access = nil
        refresh = nil
    }

    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { accessToken }
}
