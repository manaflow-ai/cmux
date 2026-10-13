#if os(iOS)
import CnxAuth
import CnxDesign
import CnxFeed
import CnxLive
import CnxModel
import CnxTransport
import CnxOnboarding
import CnxSettings
import SwiftUI
import OSLog
import UIKit

private let log = Logger(subsystem: "dev.cmux.cnx", category: "shell")
private let theme = CnxTheme.standard

/// Launch options read from the process (DEBUG verification hooks included).
public struct ShellLaunchOptions: Sendable {
    public var initialTab: String?
    public var sidebarOpen = false
    public var demo: String?
    public var forceSetup = false
    public var initialEmail: String?

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        #if DEBUG
        initialTab = value("-cnx-tab")
        sidebarOpen = arguments.contains("-cnx-sidebar-open")
        demo = value("-cnx-demo") ?? DeveloperOptions.launchDemo.flatMap { DemoDriver.names.contains($0) ? $0 : nil }
        forceSetup = arguments.contains("-cnx-setup")
        initialEmail = value("-cnx-email")
        #endif
    }
}

/// The app's root: launch handoff, then Welcome (signed out), first-run setup,
/// or the shell (signed in).
public struct RootView: View {
    @State private var auth: CnxAuthModel
    @State private var store: AppStore
    @State private var settings = SettingsStore()
    @State private var sidebar = SidebarModel()
    @State private var launchFinished = false
    /// Set right after the launch handoff: later Welcome insertions (sign-out)
    /// crossfade instead of replaying the launch intro.
    @State private var handoffDone = false
    @AppStorage("cnx.setupComplete") private var setupComplete = false
    private let options: ShellLaunchOptions

    public init(auth: CnxAuthModel, store: AppStore, options: ShellLaunchOptions = ShellLaunchOptions()) {
        _auth = State(initialValue: auth)
        // Live auth: teams come only from Stack (the mock list stays for mock mode).
        if !auth.isMock {
            store.teams = []
            store.activeTeamID = ""
        }
        _store = State(initialValue: store)
        self.options = options
    }

    private enum Destination: Hashable { case welcome, setup, shell }

    private var destination: Destination {
        guard auth.isSignedIn else { return .welcome }
        return setupComplete && !options.forceSetup ? .shell : .setup
    }

    public var body: some View {
        ZStack {
            theme.colors.bg.color.ignoresSafeArea()
            if launchFinished {
                Group {
                    switch destination {
                    case .welcome:
                        WelcomeView(auth: auth, playsLaunchIntro: !handoffDone, initialEmail: options.initialEmail)
                    case .setup:
                        SetupFlow(steps: setupSteps, auth: auth, store: store) {
                            setupComplete = true
                            theme.haptics.success()
                        }
                    case .shell:
                        ShellView(store: store, auth: auth, settings: settings, sidebar: sidebar, options: options)
                    }
                }
                .transition(.opacity.animation(theme.motion.gentle.animation))
            } else {
                LaunchMarkView()
                    .ignoresSafeArea()
                    .transition(.opacity.combined(with: .scale(scale: 0.92)).animation(theme.motion.snap.animation))
            }
        }
        .animation(theme.motion.gentle.animation, value: destination)
        .task(id: auth.isResolved) {
            guard auth.isResolved, !launchFinished else { return }
            syncTeams()
            if destination == .welcome {
                // Welcome draws the launch mark itself on its first frame and
                // animates it from there, so the swap must not fade either side.
                var cut = Transaction()
                cut.disablesAnimations = true
                withTransaction(cut) { launchFinished = true }
            } else {
                withAnimation(theme.motion.gentle.animation) { launchFinished = true }
            }
        }
        .onChange(of: launchFinished) { _, finished in handoffDone = finished }
        .onChange(of: auth.teams) { _, _ in syncTeams() }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn { theme.haptics.success() }
        }
        .onChange(of: settings.appearance, initial: true) { _, mode in
            applyAppearance(mode)
        }
    }

    private var setupSteps: [SetupFlow.Step] {
        var steps: [SetupFlow.Step] = []
        if store.teams.isEmpty || store.teams.count >= 2 { steps.append(.team) }
        if store.activeTeam?.macs.isEmpty ?? true { steps.append(.pairMac) }
        steps.append(.notifications)
        return steps
    }

    private func syncTeams() {
        let teams = auth.teams
        log.info("Stack teams: \(teams.count, privacy: .public)")
        guard !teams.isEmpty else { return }
        if auth.isMock {
            store.applyAccountTeams(teams, selectedID: auth.selectedTeamID)
        } else {
            // Live: Macs come from the cnx-ios service, never the samples.
            store.applyLiveTeams(teams, selectedID: auth.selectedTeamID)
        }
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        let style: UIUserInterfaceStyle = switch mode {
        case .light: .light
        case .dark: .dark
        case .system: .unspecified
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}

/// The signed-in shell: the UIKit drawer container with the team sidebar under
/// a four-tab `TabView`.
struct ShellView: View {
    @State private var shell: ShellModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var inviteEmail = ""
    private let options: ShellLaunchOptions

    init(store: AppStore, auth: CnxAuthModel, settings: SettingsStore, sidebar: SidebarModel, options: ShellLaunchOptions) {
        let shell = ShellModel(store: store, auth: auth, settings: settings, sidebar: sidebar)
        if let tab = options.initialTab.flatMap(RootTab.init(rawValue:)) { shell.tab = tab }
        _shell = State(initialValue: shell)
        self.options = options
    }

    var body: some View {
        SidebarContainer(
            model: shell.sidebar,
            sidebar: TeamSidebar(store: shell.store, shell: shell, sidebar: shell.sidebar),
            content: ShellTabs(shell: shell).environment(shell.store)
        )
        .ignoresSafeArea()
        .cnxToast($shell.toast)
        .sheet(item: $shell.shareURL) { item in
            ShareSheet(url: item.url).presentationDetents([.medium, .large])
        }
        .sheet(item: $shell.editingTeam) { team in
            TeamAppearanceEditor(team: team) { shell.saveAppearance($0, for: team) }
        }
        .alert("Invite to \(shell.invitingTeam?.name ?? "team")", isPresented: Binding(
            get: { shell.invitingTeam != nil },
            set: { if !$0 { shell.invitingTeam = nil } }
        )) {
            TextField("Email", text: $inviteEmail)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
            Button("Cancel", role: .cancel) { inviteEmail = "" }
            Button("Send") {
                if let team = shell.invitingTeam { shell.sendInvite(email: inviteEmail, to: team) }
                inviteEmail = ""
            }
        } message: {
            Text("They'll get an email invitation to join.")
        }
        .onChange(of: shell.auth.teams) { _, teams in
            shell.live?.applyAccountTeams(teams, selectedID: shell.store.activeTeamID)
        }
        .onChange(of: shell.settings.transport) { _, transport in
            shell.live?.setTransport(transport.link)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { shell.live?.foreground() }
        }
        .task {
            startLive()
            if options.sidebarOpen { shell.sidebar.open() }
            #if DEBUG
            if let demo = options.demo { await DemoDriver(shell: shell).run(demo) }
            await DebugLaunch.run(selectTab: { shell.tab = $0 })
            #endif
        }
    }
}

extension ShellView {
    /// Signed in for real with a service URL: replace mocks with live data.
    @MainActor
    private func startLive() {
        let auth = shell.auth
        guard shell.live == nil, !auth.isMock, let base = auth.apiBaseURL, let user = auth.user else { return }
        let api = LiveAPI(baseURL: base) { try await auth.accessToken(forceRefresh: $0) }
        let live = LiveCoordinator(
            store: shell.store,
            api: api,
            identity: DeviceIdentity.load(),
            userID: user.id,
            deviceName: UIDevice.current.name,
            transport: shell.settings.transport.link,
            dialer: FFIMacLinkDialer()
        )
        shell.live = live
        shell.terminalTabs.sessionProvider = { [weak live] tab in live?.terminalSession(tabID: tab.id, programName: tab.title) }
        live.applyAccountTeams(auth.teams, selectedID: auth.selectedTeamID)
        log.info("live data on \(base.host() ?? "", privacy: .public)")
    }
}

extension CnxModel.TransportKind {
    /// The link layer's transport for the Settings choice.
    var link: CnxTransport.TransportKind { self == .webrtc ? .webRTC : .wireGuard }
}

/// Exactly four tabs: Home, Workspaces, Feed, Settings. The selected tab is
/// `label` (neutral accent), never blue.
struct ShellTabs: View {
    let shell: ShellModel

    var body: some View {
        @Bindable var shell = shell
        TabView(selection: $shell.tab) {
            Tab("Home", systemImage: "house", value: RootTab.home) {
                HomeScreen(shell: shell)
            }
            Tab("Workspaces", systemImage: "square.stack.3d.up", value: RootTab.workspaces) {
                WorkspacesScreen(shell: shell)
            }
            .badge(shell.store.activeWorkspaces.filter(\.needsAttention).count)
            Tab("Feed", systemImage: "bubble.left.and.text.bubble.right", value: RootTab.feed) {
                CnxFeed.FeedScreen { SidebarToolbarItem(sidebar: shell.sidebar) }
            }
            .badge(FeedStore.shared.needsYouCount)
            Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                SettingsScreen(
                    auth: shell.auth,
                    store: shell.store,
                    settings: shell.settings,
                    path: $shell.settingsPath,
                    scrollRequest: shell.settingsScrollTarget,
                    inviteToTeam: { shell.invite(to: $0) }
                ) {
                    SidebarToolbarItem(sidebar: shell.sidebar)
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(theme.colors.label.color)
        .cnxSensoryFeedback(.selection, trigger: shell.tab)
    }
}

#if DEBUG
/// DEBUG launch arguments: `-CnxDemo chat-feed` runs the Feed + agent chat demo driver;
/// `-CnxDemo acp-parity` the Feed swipe, artifacts, subagents, checkpoints and handoff driver.
struct DebugLaunch {
    @MainActor
    static func run(selectTab: (RootTab) -> Void) async {
        let arguments = ProcessInfo.processInfo.arguments
        let name: String
        if let index = arguments.firstIndex(of: "-CnxDemo"), arguments.indices.contains(index + 1) {
            name = arguments[index + 1]
        } else if let picked = DeveloperOptions.launchDemo {
            name = picked
        } else {
            return
        }
        switch name {
        case "chat-feed":
            selectTab(.feed)
            await FeedDemoScript().run()
        case "acp-parity":
            selectTab(.feed)
            await ParityDemoScript().run()
        default:
            break
        }
    }
}
#endif
#endif
