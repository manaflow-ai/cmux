import CMUXAuthCore
import CmuxAuthRuntime
import Foundation

/// Holds team loading across the pairing deadline without making network requests.
actor MobilePairingRecoveryAuthClient: AuthClient {
    static let user = CMUXAuthUser(id: "pairing-recovery", primaryEmail: "pairing@example.test", displayName: "Pairing")
    private var failTeamRequests = false
    private var teamRequestCount = 0
    private var teamResult: CheckedContinuation<[CMUXAuthTeam], Never>?
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func failTeams(_ fail: Bool) { failTeamRequests = fail }

    func waitForTeamRequest(_ count: Int) async {
        guard teamRequestCount < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func completeTeamRequest() {
        let continuation = teamResult
        teamResult = nil
        continuation?.resume(returning: [CMUXAuthTeam(id: "pairing-team", displayName: "Pairing")])
    }

    func listTeams() async throws -> [CMUXAuthTeam] {
        teamRequestCount += 1
        if failTeamRequests { throw URLError(.notConnectedToInternet) }
        return await withCheckedContinuation { continuation in
            teamResult = continuation
            let ready = requestWaiters.filter { $0.0 <= teamRequestCount }
            requestWaiters.removeAll { $0.0 <= teamRequestCount }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func accessToken() async -> String? { "fixture-access" }
    func refreshToken() async -> String? { "fixture-refresh" }
    func forceRefreshAccessToken() async -> String? { "fixture-access" }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? { Self.user }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "fixture" }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}
    func storedAccessToken() async -> String? { "fixture-access" }
    func clearLocalSession() async {}
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {}
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { accessToken }
}
