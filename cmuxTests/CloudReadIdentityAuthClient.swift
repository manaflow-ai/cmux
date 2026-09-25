import CMUXAuthCore
import CmuxAuthRuntime
import Foundation

/// Holds only the revalidation token probe; coherent token reads remain available.
actor CloudReadIdentityAuthClient: AuthClient {
    private var accountID: String? = "fixture"
    private var holdsProbe = false
    private var probe: CheckedContinuation<Void, Never>?
    private var probeWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdsTeamList = false
    private var teamListRequested = false
    private var teamListProbe: CheckedContinuation<Void, Never>?
    private var teamListWaiters: [CheckedContinuation<Void, Never>] = []

    func holdValidationProbe() { holdsProbe = true }
    func waitUntilValidationProbe() async {
        if probe != nil { return }
        await withCheckedContinuation { probeWaiters.append($0) }
    }
    func releaseValidationProbe() {
        holdsProbe = false
        probe?.resume()
        probe = nil
    }
    func holdTeamList() { holdsTeamList = true }
    func waitUntilTeamListRequested() async {
        if teamListRequested { return }
        await withCheckedContinuation { teamListWaiters.append($0) }
    }
    func releaseTeamList() {
        holdsTeamList = false
        teamListProbe?.resume()
        teamListProbe = nil
    }
    func accessToken() async -> String? {
        if holdsProbe {
            await withCheckedContinuation { continuation in
                probe = continuation
                let waiters = probeWaiters
                probeWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        return accountID.map { "fixture-access-\($0)" }
    }
    func resolvedAccessToken(forceRefresh: Bool) async throws -> String? { accountID.map { "fixture-access-\($0)" } }
    func refreshToken() async -> String? { accountID.map { "fixture-refresh-\($0)" } }
    func forceRefreshAccessToken() async -> String? { accountID.map { "fixture-access-\($0)" } }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        accountID.map { CMUXAuthUser(id: $0, primaryEmail: "\($0)@example.test", displayName: "Fixture") }
    }
    func listTeams() async throws -> [CMUXAuthTeam] {
        if holdsTeamList {
            teamListRequested = true
            await withCheckedContinuation { continuation in
                teamListProbe = continuation
                let waiters = teamListWaiters
                teamListWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        [CMUXAuthTeam(id: "selected", displayName: "Selected")]
    }
    func setSelectedTeam(id: String?) async throws {}
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "fixture" }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws { accountID = "replacement" }
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}
    func storedAccessToken() async -> String? { accountID.map { "fixture-access-\($0)" } }
    func clearLocalSession() async { accountID = nil }
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {
        guard let accountID, refreshToken == "fixture-refresh-\(accountID)" else { return }
        self.accountID = nil
    }
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { accessToken }
}
