import Foundation
import Observation

/// The app's observable state. Sources (mock now, link-backed later) write into it.
@MainActor
@Observable
public final class AppStore {
    public var teams: [Team]
    public var activeTeamID: String
    public var workspaces: [Workspace]
    public var feed: [FeedEvent]
    /// The last tab the user had open per workspace on this device.
    public var lastTabByWorkspace: [String: String] = [:]
    /// Load state of the active team's live data (skeletons until the first
    /// `hello` frame; a failure shows the list-level error state).
    public var teamDataState: LoadState = .loaded
    /// Whether the device has network (drives the offline banner).
    public var isOffline = false

    /// Phases of a remote load.
    public enum LoadState: Hashable, Sendable {
        case loading, loaded, failed
    }

    public init(teams: [Team], activeTeamID: String, workspaces: [Workspace], feed: [FeedEvent]) {
        self.teams = teams
        self.activeTeamID = activeTeamID
        self.workspaces = workspaces
        self.feed = feed
    }

    public var activeTeam: Team? {
        teams.first { $0.id == activeTeamID }
    }

    public func selectTeam(_ id: String) {
        guard teams.contains(where: { $0.id == id }) else { return }
        activeTeamID = id
        UserDefaults.standard.set(id, forKey: Self.lastTeamKey)
    }

    public func setAppearance(_ appearance: TeamAppearance, for teamID: String) {
        guard let index = teams.firstIndex(where: { $0.id == teamID }) else { return }
        teams[index].appearance = appearance
        if let data = try? JSONEncoder().encode(appearance) {
            UserDefaults.standard.set(data, forKey: Self.appearanceKey(teamID))
        }
    }

    /// Replaces the team list with the signed-in account's Stack teams. Macs
    /// stay mock until the `cnx-ios-api` presence link exists: each team gets
    /// one of the sample Mac sets by position. Appearance is per user per team
    /// and persists locally until `PUT /v1/teams/:id/prefs` is wired.
    public func applyAccountTeams(_ accountTeams: [AccountTeam], selectedID: String?) {
        let sampleMacs = AppStore.mock().teams.map(\.macs)
        teams = accountTeams.enumerated().map { index, team in
            Team(
                id: team.id,
                name: team.name,
                appearance: Self.storedAppearance(team.id),
                macs: sampleMacs.isEmpty ? [] : sampleMacs[index % sampleMacs.count]
            )
        }
        let remembered = UserDefaults.standard.string(forKey: Self.lastTeamKey)
        let candidates = [selectedID, remembered, teams.first?.id].compactMap { $0 }
        activeTeamID = candidates.first { id in teams.contains { $0.id == id } } ?? ""
    }

    /// A Stack Auth team as the account reports it.
    public struct AccountTeam: Hashable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    private static let lastTeamKey = "cnx.lastTeamID"
    private static func appearanceKey(_ teamID: String) -> String { "cnx.teamAppearance.\(teamID)" }

    private static func storedAppearance(_ teamID: String) -> TeamAppearance? {
        guard let data = UserDefaults.standard.data(forKey: appearanceKey(teamID)) else { return nil }
        return try? JSONDecoder().decode(TeamAppearance.self, from: data)
    }

    /// Workspaces on the active team's Macs.
    public var activeWorkspaces: [Workspace] {
        let macIDs = Set(activeTeam?.macs.map(\.id) ?? [])
        return workspaces.filter { macIDs.contains($0.macID) }
    }

    /// The tab a workspace opens to: the last one used on this device, else its first tab.
    public func openingTab(for workspace: Workspace) -> WorkspaceTab? {
        if let id = lastTabByWorkspace[workspace.id], let tab = workspace.tabs.first(where: { $0.id == id }) {
            return tab
        }
        return workspace.tabs.first
    }

    public func noteOpened(tabID: String, in workspaceID: String) {
        lastTabByWorkspace[workspaceID] = tabID
    }
}
