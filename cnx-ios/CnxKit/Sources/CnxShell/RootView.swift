#if os(iOS)
import CnxAuth
import CnxDesign
import CnxModel
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
        demo = value("-cnx-demo")
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
                        WelcomeView(auth: auth, initialEmail: options.initialEmail)
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
            withAnimation(theme.motion.gentle.animation) { launchFinished = true }
        }
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
        store.applyAccountTeams(teams, selectedID: auth.selectedTeamID)
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
            content: ShellTabs(shell: shell)
        )
        .ignoresSafeArea()
        .cnxToast($shell.toast)
        .sheet(item: $shell.shareURL) { item in
            ShareSheet(url: item.url).presentationDetents([.medium, .large])
        }
        .sheet(item: $shell.editingTeam) { team in
            TeamAppearanceEditor(team: team) { shell.store.setAppearance($0, for: team.id) }
        }
        .task {
            if options.sidebarOpen { shell.sidebar.open() }
            #if DEBUG
            if let demo = options.demo { await DemoDriver(shell: shell).run(demo) }
            #endif
        }
    }
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
                FeedScreen(shell: shell)
            }
            .badge(shell.store.feed.filter { !$0.isResolved }.count)
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
#endif
