#if os(iOS)
import CnxAgentChat
import CnxAuth
import CnxBrowserStream
import CnxDesign
import CnxLive
import CnxModel
import CnxSettings
import CnxTerminal
import Observation
import OSLog
import SwiftUI

private let theme = CnxTheme.standard
private let shellLog = Logger(subsystem: "dev.cmux.cnx", category: "shell")

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
    @ObservationIgnored let terminalTabs = GhosttyTerminalTabContent()
    let sidebar: SidebarModel
    /// New workspaces: the linked Mac's daemon once live data starts; before
    /// that nothing can be created (the mock only in DEBUG mock mode).
    let creator: WorkspaceCreator
    #if DEBUG
    /// The mock backend (DEBUG demos make it refuse once).
    let mockCreation: MockWorkspaceCreationBackend
    #endif
    /// The backend with no live data.
    private let offlineCreation: any WorkspaceCreationBackend

    var tab: RootTab = .home { didSet { updateInteractiveOpen() } }
    var homePath = NavigationPath() { didSet { updateInteractiveOpen() } }
    /// Typed: a workspace page must not nest a SwiftUI NavigationStack (the
    /// terminal tab hosts its own page), or SwiftUI traps with
    /// `comparisonTypeMismatch` when the nested stack joins this path.
    var workspacesPath: [Workspace] = [] { didSet { updateInteractiveOpen() } }
    var feedPath: [AgentChatDestination] = [] { didSet { updateInteractiveOpen() } }
    var settingsPath: [SettingsRoute] = [] { didSet { updateInteractiveOpen() } }

    var toast: CnxToast?
    var editingTeam: Team?
    /// Live data (signed in for real with a `cnx-ios-api` base URL); nil in mock mode.
    var live: LiveCoordinator?
    /// Settings → Connection's device list and account deletion (live mode).
    private(set) var deviceDirectory: (any SettingsDeviceDirectory)?
    /// DEBUG mock mode (Settings → Developer → Mock data): sample content only.
    private let mockMode: Bool
    /// The team an email invite is being written for (live mode).
    var invitingTeam: Team?
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
        // Mock content only in DEBUG mock mode (mock auth); a live account
        // never falls back to it.
        let mockMode = TerminalSessionChoice.mockCompiledIn && auth.isMock
        self.mockMode = mockMode
        #if DEBUG
        // `-cnx-mock-create-delay <seconds>` holds mock creations open, so
        // the list's pending row can be seen (verify/record-wsdesign.sh).
        let delay = UserDefaults.standard.double(forKey: "cnx-mock-create-delay")
        let mock = delay > 0 ? MockWorkspaceCreationBackend(latency: .seconds(delay)) : MockWorkspaceCreationBackend()
        mockCreation = mock
        offlineCreation = mockMode ? mock : UnavailableWorkspaceCreationBackend()
        #else
        offlineCreation = UnavailableWorkspaceCreationBackend()
        #endif
        creator = WorkspaceCreator(store: store, backend: offlineCreation)
        terminalTabs.mockDataEnabled = mockMode
        terminalTabs.macName = { [weak store] workspace in
            store?.teams.flatMap(\.macs).first { $0.id == workspace.macID }?.name
        }
        creator.onFailure = { [weak self] placeholder, message in
            self?.workspaceCreationFailed(placeholder, message: message)
        }
        creator.onManageFailure = { [weak self] _, what, message in
            self?.toast = CnxToast(symbol: "exclamationmark.circle", text: what)
            theme.haptics.error()
            shellLog.error("\(what, privacy: .public): \(message, privacy: .public)")
        }
    }

    /// Points terminal tabs and new workspaces at `live`, or back at the
    /// offline fallbacks when it is nil (the mocks only in DEBUG mock mode). RootView creates the coordinator when the account
    /// resolves, which can be after this shell was built (a restored session,
    /// a DEBUG auto sign-in), so this runs on every change, not once.
    func attach(live: LiveCoordinator?) {
        if self.live !== live, self.live != nil { terminalTabs.reset() }
        self.live = live
        deviceDirectory = live.map(LiveDeviceDirectory.init(live:))
        #if DEBUG
        if live == nil, mockMode { deviceDirectory = MockDeviceDirectory(store: store) }
        #endif
        live?.onMacRemoved = { [weak self] macID in self?.macRemoved(macID) }
        if let live {
            terminalTabs.sessionProvider = { [weak live] tab in live?.terminalSession(tabID: tab.id, programName: tab.title) }
            terminalTabs.artifactSourceProvider = { [weak live] tab in live?.terminalArtifactSource(tabID: tab.id) }
            terminalTabs.uploaderProvider = { [weak live] tab in live?.terminalUploader(tabID: tab.id) }
            let backend = LiveWorkspaceCreationBackend(sync: live.workspaces, link: live.link, acpmux: live.acpmux)
            // New Browser Tab only for a Mac that streams browser tabs (`browser-stream-v1`).
            backend.capabilities = { [weak store] mac in store?.macCapabilities[mac] }
            creator.backend = backend
            StreamedBrowserDirectory.shared.opener = { [weak live] in await live?.browserLink() }
        } else {
            StreamedBrowserDirectory.shared.opener = nil
            terminalTabs.sessionProvider = nil
            terminalTabs.artifactSourceProvider = nil
            terminalTabs.uploaderProvider = nil
            creator.backend = offlineCreation
        }
    }

    /// A Mac left the account: a workspace page of it (and anything pushed
    /// on top) closes, back to the list.
    func macRemoved(_ macID: String) {
        if let index = workspacesPath.firstIndex(where: { $0.macID == macID }) {
            workspacesPath.removeSubrange(index...)
        }
    }

    /// Opens a tapped notification: Chief's reply on Home, an agent's event in
    /// its chat. Returns false while the tab is not known yet (the Mac's tree
    /// has not arrived), so the shell tries again when it does.
    @discardableResult
    func open(_ route: NotificationRoute) -> Bool {
        if route.kind == "chief" {
            tab = .home
            return true
        }
        guard let destination = live?.destination(sessionID: route.sessionID, workspaceID: route.workspaceID, tabID: route.tabID) else {
            // The Feed lists the event meanwhile.
            tab = .feed
            return false
        }
        tab = .feed
        feedPath = [destination]
        return true
    }

    /// Whether the route's chat is on screen now (its notification shows no banner).
    func isShowing(_ route: NotificationRoute) -> Bool {
        guard UIApplication.shared.applicationState == .active, tab == .feed, let shown = feedPath.last,
              let destination = live?.destination(sessionID: route.sessionID, workspaceID: route.workspaceID, tabID: route.tabID) else { return false }
        return destination == shown
    }

    /// The Mac refused a new workspace: its row is already gone; leave its
    /// screen if it is open, and say so.
    private func workspaceCreationFailed(_ placeholder: Workspace, message: String) {
        if let index = workspacesPath.firstIndex(where: { $0.id == placeholder.id }) {
            workspacesPath.removeSubrange(index...)
        }
        let mac = store.teams.flatMap(\.macs).first { $0.id == placeholder.macID }?.name ?? "the Mac"
        toast = CnxToast(symbol: "exclamationmark.circle", text: "Couldn't create a workspace on \(mac)")
        theme.haptics.error()
        shellLog.error("new workspace on \(mac, privacy: .public) refused: \(message, privacy: .public)")
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
        live?.activeTeamChanged(byUser: true)
        guard !id.hasPrefix("personal-") else { return }
        Task { await auth.selectTeam(id) }
    }

    /// The banner over Workspaces: no network first, then the live link (SPEC 7.4).
    var banner: ConnectionBannerState? {
        if store.isOffline { return .offline }
        // Pairing (verify/phone-approvals.md): the Mac asks the user the first time.
        switch live?.pairingState {
        case .waiting(let mac)?: return .waitingForPairing(on: mac)
        case .waitingAfterNewKeys(let mac)?: return .waitingForPairingAfterNewKeys(on: mac)
        case .denied(let mac)?: return .failed("\(mac) did not allow this iPhone")
        case .failed(let reason)?: return .failed("Pairing failed: \(reason)")
        default: return live?.banner
        }
    }

    /// Saves a team's color and emoji (and `PUT /prefs` when live).
    func saveAppearance(_ appearance: TeamAppearance, for team: Team) {
        guard let live else {
            store.setAppearance(appearance, for: team.id)
            return
        }
        Task {
            do {
                try await live.saveAppearance(appearance, teamID: team.id)
            } catch {
                toast = CnxToast(symbol: "exclamationmark.circle", text: "Saved on this iPhone only")
            }
        }
    }

    /// Live mode: `POST /v1/teams/:id/invites {email}` (Stack emails the invitation).
    func sendInvite(email: String, to team: Team) {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let live, !address.isEmpty else { return }
        isFetchingInvite = true
        Task {
            defer { isFetchingInvite = false }
            do {
                try await live.invite(email: address, teamID: team.id)
                toast = CnxToast(symbol: "envelope", text: "Invitation sent to \(address)")
                theme.haptics.success()
            } catch {
                toast = CnxToast(symbol: "exclamationmark.circle", text: "Couldn't send the invitation")
                theme.haptics.error()
            }
        }
    }

    func invite(to team: Team) {
        if live != nil {
            if team.id.hasPrefix("personal-") {
                toast = CnxToast(symbol: "person.2", text: "Create a team to invite people")
            } else {
                invitingTeam = team
            }
            return
        }
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
                if let live {
                    live.applyAccountTeams(teams.filter { !$0.id.hasPrefix("personal-") }, selectedID: team.id)
                } else {
                    store.applyAccountTeams(teams, selectedID: store.activeTeamID)
                }
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
