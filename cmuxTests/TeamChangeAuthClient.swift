import CMUXAuthCore
import CmuxAuthRuntime
import Foundation

/// Serves two teams and can hold the next team create or team switch open
/// until the test releases it, so a test can start a second change mid-flight.
actor TeamChangeAuthClient: AuthClient {
    private var teams = [
        CMUXAuthTeam(id: "team-a", displayName: "Team A"),
        CMUXAuthTeam(id: "team-b", displayName: "Team B"),
    ]
    private(set) var createCount = 0
    private(set) var selectCount = 0
    private var holdsNextCreate = false
    private var holdsNextSelect = false
    private var heldCreate: CheckedContinuation<Void, Never>?
    private var heldSelect: CheckedContinuation<Void, Never>?

    func holdNextCreate() { holdsNextCreate = true }
    func holdNextSelect() { holdsNextSelect = true }
    var isHoldingCreate: Bool { heldCreate != nil }
    var isHoldingSelect: Bool { heldSelect != nil }

    func releaseCreate() {
        heldCreate?.resume()
        heldCreate = nil
    }

    func releaseSelect() {
        heldSelect?.resume()
        heldSelect = nil
    }

    func createTeam(displayName: String) async throws -> CMUXAuthTeam {
        createCount += 1
        let team = CMUXAuthTeam(id: "team-new-\(createCount)", displayName: displayName)
        if holdsNextCreate {
            holdsNextCreate = false
            await withCheckedContinuation { heldCreate = $0 }
        }
        teams.append(team)
        return team
    }

    func setSelectedTeam(id: String?) async throws {
        selectCount += 1
        if holdsNextSelect {
            holdsNextSelect = false
            await withCheckedContinuation { heldSelect = $0 }
        }
    }

    func listTeams() async throws -> [CMUXAuthTeam] { teams }
    func accessToken() async -> String? { "fixture-access" }
    func refreshToken() async -> String? { "fixture-refresh" }
    func forceRefreshAccessToken() async -> String? { "fixture-access" }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        CMUXAuthUser(id: "fixture", primaryEmail: "fixture@example.test", displayName: "Fixture")
    }
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
