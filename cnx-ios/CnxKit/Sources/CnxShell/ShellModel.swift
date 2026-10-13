#if os(iOS)
import CnxAuth
import CnxDesign
import CnxModel
import CnxSettings
import Observation
import SwiftUI

private let theme = CnxTheme.standard

/// Root tabs. Exactly four; there is no Search tab.
enum RootTab: String, Hashable, CaseIterable {
    case home, workspaces, feed, settings
}

/// Shell-level state and actions shared by the tabs and the sidebar.
@MainActor
@Observable
final class ShellModel {
    let store: AppStore
    let auth: CnxAuthModel
    let settings: SettingsStore
    let sidebar: SidebarModel

    var tab: RootTab = .home { didSet { updateInteractiveOpen() } }
    var homePath: [String] = [] { didSet { updateInteractiveOpen() } }
    var workspacesPath: [Workspace] = [] { didSet { updateInteractiveOpen() } }
    var feedPath: [String] = [] { didSet { updateInteractiveOpen() } }
    var settingsPath: [SettingsRoute] = [] { didSet { updateInteractiveOpen() } }

    var toast: CnxToast?
    var editingTeam: Team?
    var isFetchingInvite = false
    var shareURL: ShareItem?
    /// Debug-driven scroll target for the Settings list.
    var settingsScrollTarget: String?

    struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    init(store: AppStore, auth: CnxAuthModel, settings: SettingsStore, sidebar: SidebarModel) {
        self.store = store
        self.auth = auth
        self.settings = settings
        self.sidebar = sidebar
    }

    /// The drawer pan only opens from a tab root (stack depth 1).
    private func updateInteractiveOpen() {
        let depth = switch tab {
        case .home: homePath.count
        case .workspaces: workspacesPath.count
        case .feed: feedPath.count
        case .settings: settingsPath.count
        }
        sidebar.allowsInteractiveOpen = depth == 0
    }

    /// Row tap: selection haptic, highlight moves, drawer closes, content
    /// crossfades to the new team (SPEC 3.3 "Team switch").
    func switchTeam(to id: String) {
        guard id != store.activeTeamID else {
            sidebar.close()
            return
        }
        theme.haptics.selection()
        sidebar.crossfadeContent()
        withAnimation(theme.motion.snap.animation) {
            store.selectTeam(id)
        }
        workspacesPath.removeAll()
        sidebar.close()
        Task { await auth.selectTeam(id) }
    }

    func invite(to team: Team) {
        guard !isFetchingInvite else { return }
        isFetchingInvite = true
        Task {
            defer { isFetchingInvite = false }
            do {
                let url = try await auth.inviteLink(teamID: team.id)
                shareURL = ShareItem(url: url)
            } catch CnxAuthModel.InviteError.serviceUnavailable {
                toast = CnxToast(symbol: "link", text: "Invite links need the cmux service")
            } catch {
                toast = CnxToast(symbol: "exclamationmark.circle", text: "Couldn't create an invite link")
                theme.haptics.error()
            }
        }
    }

    func createTeam(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                let team = try await auth.createTeam(named: trimmed)
                var teams = store.teams.map { AppStore.AccountTeam(id: $0.id, name: $0.name) }
                if !teams.contains(where: { $0.id == team.id }) { teams.append(team) }
                store.applyAccountTeams(teams, selectedID: store.activeTeamID)
                theme.haptics.success()
                switchTeam(to: team.id)
            } catch {
                toast = CnxToast(symbol: "exclamationmark.circle", text: "Couldn't create the team")
                theme.haptics.error()
            }
        }
    }

    func joinTeam(inviteLink: String) {
        Task {
            do {
                try await auth.joinTeam(inviteLink: inviteLink)
                toast = CnxToast(symbol: "checkmark", text: "Joined the team")
                theme.haptics.success()
            } catch {
                toast = CnxToast(symbol: "exclamationmark.circle", text: "That invite link didn't work")
                theme.haptics.error()
            }
        }
    }
}

/// `UIActivityViewController` for invite links.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
