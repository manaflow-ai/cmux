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
    }

    public func setAppearance(_ appearance: TeamAppearance, for teamID: String) {
        guard let index = teams.firstIndex(where: { $0.id == teamID }) else { return }
        teams[index].appearance = appearance
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
