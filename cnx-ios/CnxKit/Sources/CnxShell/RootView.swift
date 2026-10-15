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
    /// DEBUG: open setup on the Connect your Mac step, with no Mac until a
    /// few seconds in (the presence flip, for recordings).
    public var setupPairDemo = false
    /// DEBUG: open Settings on this page (`SettingsRoute` case name).
    public var settingsPage: String?

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
        setupPairDemo = arguments.contains("-cnx-setup-pair")
        if setupPairDemo { forceSetup = true }
        settingsPage = value("-cnx-settings-page")
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
    /// Live data from sign-in on (setup included); nil in mock mode.
    @State private var live: LiveCoordinator?
    /// Setup's steps, fixed once the team list has loaded so a Mac appearing
    /// mid-setup does not swap the page under the user.
    @State private var setupPlan: [SetupFlow.Step]?
    /// Whether setup asks for notifications (a push build the system has not
    /// asked yet); nil until known.
    @State private var asksNotifications: Bool?
    /// The launch handed off straight to Welcome: Welcome is cut in (it
    /// redraws the launch mark and plays its intro) instead of crossfading.
    /// Fixed for the session, so a Welcome rebuilt mid-intro keeps playing;
    /// cleared on sign-out, where Welcome crossfades in, settled.
    @State private var welcomeCut = false
    @AppStorage("cnx.setupComplete") private var setupComplete = false
    private let options: ShellLaunchOptions

    public init(auth: CnxAuthModel, store: AppStore, options: ShellLaunchOptions = ShellLaunchOptions()) {
        _auth = State(initialValue: auth)
        // Live auth: teams, Macs and workspaces come only from Stack and the
        // Mac (the sample data stays only for mock mode).
        if !auth.isMock {
            store.teams = []
            store.activeTeamID = ""
            store.workspaces = []
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
                        WelcomeView(auth: auth, playsLaunchIntro: welcomeCut, initialEmail: options.initialEmail)
                    case .setup:
                        SetupFlow(
                            steps: setupSteps, auth: auth, store: store,
                            signOut: { Task { await auth.signOut() } },
                            teamPicked: { _ in live?.activeTeamChanged() },
                            personalPicked: { live?.selectPersonal() },
                            teamCreated: teamCreated
                        ) {
                            setupComplete = true
                            theme.haptics.success()
                        }
                    case .shell:
                        ShellView(store: store, auth: auth, settings: settings, sidebar: sidebar, live: live, options: options)
                    }
                }
                // The launch-to-Welcome swap is a cut on both sides (an
                // animation attached to a transition ignores the cut's
                // transaction); every other swap crossfades, Welcome's exit
                // after sign-in included.
                .transition(welcomeCut && destination == .welcome
                    ? .asymmetric(insertion: .identity, removal: .opacity.animation(theme.motion.gentle.animation))
                    : .opacity.animation(theme.motion.gentle.animation))
            } else {
                // Welcome redraws this mark on its first frame and animates it
                // from there, so on that path the swap is a true cut: an
                // animated removal would leave a second, fading chevron behind
                // the welcome (an animation attached to a transition runs even
                // in a `disablesAnimations` transaction).
                LaunchMarkView()
                    .ignoresSafeArea()
                    .transition(destination == .welcome
                        ? .identity
                        : .opacity.combined(with: .scale(scale: 0.92)).animation(theme.motion.snap.animation))
            }
        }
        .animation(theme.motion.gentle.animation, value: destination)
        // Settings → Require Face ID (audit B11).
        .cnxAppLock(enabled: settings.requireFaceID)
        .task(id: auth.isResolved) {
            guard auth.isResolved, !launchFinished else { return }
            syncTeams()
            if destination == .welcome {
                // Welcome draws the launch mark itself on its first frame and
                // animates it from there, so the swap must not fade either side.
                var cut = Transaction()
                cut.disablesAnimations = true
                withTransaction(cut) {
                    welcomeCut = true
                    launchFinished = true
                }
            } else {
                withAnimation(theme.motion.gentle.animation) { launchFinished = true }
            }
            #if DEBUG
            if options.setupPairDemo { await runSetupPairDemo() }
            #endif
        }
        // Signed in (or out): live data and the team list follow the account.
        .task(id: auth.isResolved ? auth.user?.id : nil) {
            accountChanged()
            await auth.loadTeams()
        }
        .onChange(of: auth.teamList) { _, _ in syncTeams() }
        .onChange(of: auth.teamList.phase, initial: true) { _, _ in planSetup() }
        .onChange(of: asksNotifications) { _, _ in planSetup() }
        .task(id: auth.isSignedIn) {
            guard auth.isSignedIn else { return }
            asksNotifications = await SetupFlow.asksForNotifications()
        }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn { theme.haptics.success() } else { signedOut() }
        }
        .onChange(of: settings.appearance, initial: true) { _, mode in
            applyAppearance(mode)
        }
    }

    private var setupSteps: [SetupFlow.Step] {
        if options.setupPairDemo { return [.pairMac, .notifications] }
        // Until the team list loads, the team step shows its loading state
        // (and a failed list still lets the user choose Personal).
        return setupPlan ?? [.team, .pairMac] + (asksNotifications == true ? [.notifications] : [])
    }

    /// Fixes setup's steps once the account's teams are known.
    private func planSetup() {
        guard auth.teamList.isLoaded, setupPlan == nil, let asksNotifications else { return }
        var steps: [SetupFlow.Step] = []
        let count = auth.isMock ? store.teams.count : auth.teamList.teams.count
        if count != 1 { steps.append(.team) }
        if !(store.activeTeam?.macs.contains(where: \.isOnline) ?? false) { steps.append(.pairMac) }
        if asksNotifications { steps.append(.notifications) }
        setupPlan = steps
        // Nothing to set up (one team, a Mac online, notifications decided).
        if steps.isEmpty, destination == .setup { setupComplete = true }
    }

    private func syncTeams() {
        let teams = auth.teams
        log.info("Stack teams: \(teams.count, privacy: .public)")
        if let live {
            // Live: Macs come from the cnx-ios service, never the samples. An
            // account with no team uses its personal space, once that is known.
            guard auth.teamList.isLoaded else { return }
            live.applyAccountTeams(teams, selectedID: auth.selectedTeamID)
            return
        }
        guard !teams.isEmpty else { return }
        if auth.isMock {
            store.applyAccountTeams(teams, selectedID: auth.selectedTeamID)
        } else {
            store.applyLiveTeams(teams, selectedID: auth.selectedTeamID)
        }
    }

    private func teamCreated(_ team: AppStore.AccountTeam) {
        guard let live else {
            store.applyAccountTeams([team], selectedID: team.id)
            return
        }
        var teams = auth.teams
        if !teams.contains(where: { $0.id == team.id }) { teams.append(team) }
        live.applyAccountTeams(teams, selectedID: team.id)
    }

    /// Every sign-out path (setup's footer, Settings → Log out, a session the
    /// service ended) lands here: live data stops, the account's teams, Macs,
    /// workspaces and stored preferences go, the device ids are replaced (the
    /// service binds them to their first user), and Welcome crossfades in,
    /// already settled (its intro plays once per cold launch).
    private func signedOut() {
        // The phone asks the linked Mac to forget it, then deletes its keys
        // (verify/phone-approvals.md); live data stops after that try.
        if let ending = live {
            Task { @MainActor in
                await ending.unpair()
                ending.stop()
            }
        } else if !auth.isMock {
            PhoneKeys().reset()
        }
        live = nil
        setupPlan = nil
        asksNotifications = nil
        store.resetForSignOut()
        if !auth.isMock {
            DeviceIdentity.reset()
            LiveCoordinator.forgetSnapshots()
        }
        setupComplete = false
        welcomeCut = false
        log.info("signed out: account state reset")
    }

    /// Starts live data for a signed-in account (before setup, so setup sees
    /// real Macs) and stops it on sign-out.
    private func accountChanged() {
        guard let user = auth.user, auth.isSignedIn else {
            live?.stop()
            live = nil
            setupPlan = nil
            return
        }
        #if DEBUG
        if auth.isMock, store.teams.isEmpty {
            // Mock mode signed in again after a sign-out: the sample data comes back.
            let sample = AppStore.mock()
            store.teams = sample.teams
            store.activeTeamID = sample.activeTeamID
            store.workspaces = sample.workspaces
        }
        #endif
        guard live == nil, !auth.isMock, let base = auth.apiBaseURL else { return }
        let api = LiveAPI(baseURL: base) { [auth] in try await auth.accessToken(forceRefresh: $0) }
        let coordinator = LiveCoordinator(
            store: store,
            api: api,
            identity: DeviceIdentity.load(),
            userID: user.id,
            deviceName: UIDevice.current.name,
            transport: settings.transport.link,
            relayOnly: DeveloperOptions.relayOnly,
            dialer: FFIMacLinkDialer(),
            keys: PhoneKeys()
        )
        coordinator.onFollow = { [auth] teamID in
            guard !teamID.hasPrefix("personal-") else { return }
            Task { await auth.selectTeam(teamID) }
        }
        live = coordinator
        // Before the session ends (the link closes with it): stop pushes to this phone,
        // and ask the linked Mac to forget it (verify/phone-approvals.md).
        auth.willSignOut = { [weak coordinator] in
            async let push: Void = PushRegistration.shared.unregister()
            async let unpair: Void = coordinator?.unpair() ?? ()
            _ = await (push, unpair)
        }
        log.info("live data on \(base.host() ?? "", privacy: .public)")
        syncTeams()
    }

    #if DEBUG
    /// `-cnx-setup-pair`: the active team's Macs vanish, then a Mac comes
    /// online 4 s in (recording pace, not synchronization). With
    /// `-cnx-setup-pair-elsewhere` it comes online in another team, and the
    /// phone follows it there as live discovery does. With
    /// `-cnx-setup-pair-other-account` no Mac uses the account at all.
    private func runSetupPairDemo() async {
        guard let index = store.teams.firstIndex(where: { $0.id == store.activeTeamID }) else { return }
        let macs = store.teams[index].macs
        if ProcessInfo.processInfo.arguments.contains("-cnx-setup-pair-other-account") {
            // No Mac uses this account anywhere: the setup step says so.
            for i in store.teams.indices { store.teams[i].macs = [] }
            store.accountMacCount = 0
            return
        }
        let elsewhere = ProcessInfo.processInfo.arguments.contains("-cnx-setup-pair-elsewhere")
        if elsewhere {
            for i in store.teams.indices { store.teams[i].macs = [] }
        } else {
            store.teams[index].macs = []
        }
        try? await Task.sleep(for: .seconds(4))
        guard elsewhere else {
            store.teams[index].macs = macs
            return
        }
        guard let other = store.teams.first(where: { $0.id != store.activeTeamID }) else { return }
        let mac = macs.first(where: \.isOnline) ?? MacDevice(id: "mac-elsewhere", name: "Aziz's MacBook Pro", isOnline: true)
        let found = [DiscoveredMac(id: mac.id, name: mac.name, isOnline: true, teamID: other.id)]
        store.mergeDiscoveredMacs(found)
        if let team = store.teamToFollow(found, previouslyOnline: nil) {
            log.info("setup demo: following the Mac to \(team.name, privacy: .public)")
            store.selectTeam(team.id)
        }
    }
    #endif

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
    /// Settings → Developer "Relay only"; read through `DeveloperOptions`,
    /// which ignores it outside DEBUG builds.
    @AppStorage(DeveloperOptions.relayOnlyKey) private var relayOnlyPreference = false
    private let options: ShellLaunchOptions
    /// RootView's coordinator; it can arrive after the shell is built.
    private let live: LiveCoordinator?

    init(store: AppStore, auth: CnxAuthModel, settings: SettingsStore, sidebar: SidebarModel, live: LiveCoordinator?, options: ShellLaunchOptions) {
        let shell = ShellModel(store: store, auth: auth, settings: settings, sidebar: sidebar)
        shell.attach(live: live)
        if let tab = options.initialTab.flatMap(RootTab.init(rawValue:)) { shell.tab = tab }
        if let page = options.settingsPage.flatMap(SettingsRoute.init(name:)) {
            shell.tab = .settings
            shell.settingsPath = [page]
        }
        _shell = State(initialValue: shell)
        self.options = options
        self.live = live
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
        .onChange(of: shell.live?.followed) { _, followed in
            guard let followed else { return }
            shell.toast = CnxToast(symbol: "desktopcomputer", text: "\(followed.macName) is in \(followed.teamName). Switched to it.")
        }
        .onChange(of: shell.settings.transport) { _, transport in
            shell.live?.setTransport(transport.link)
        }
        .onChange(of: relayOnlyPreference) { _, _ in
            shell.live?.setRelayOnly(DeveloperOptions.relayOnly)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { shell.live?.foreground() }
        }
        // Notification taps: open now, or once the Mac's tree places the tab.
        .onChange(of: NotificationRouter.shared.pending, initial: true) { _, route in
            guard let route else { return }
            if shell.open(route) { NotificationRouter.shared.pending = nil }
        }
        .onChange(of: shell.store.workspaces) { _, _ in
            guard let route = NotificationRouter.shared.pending else { return }
            // One retry after the tree arrives; then the Feed is where it is.
            shell.open(route)
            NotificationRouter.shared.pending = nil
        }
        .onChange(of: pushKinds, initial: true) { _, kinds in
            PushRegistration.shared.setKinds(kinds)
        }
        .onAppear {
            NotificationRouter.shared.isShowing = { [weak shell] route in shell?.isShowing(route) ?? false }
        }
        .onChange(of: live.map(ObjectIdentifier.init)) { _, _ in
            shell.attach(live: live)
        }
        .task {
            if options.sidebarOpen { shell.sidebar.open() }
            #if DEBUG
            if let demo = options.demo { await DemoDriver(shell: shell).run(demo) }
            await DebugLaunch.run(selectTab: { shell.tab = $0 })
            #endif
        }
    }
}

extension ShellView {
    /// The event kinds Settings → Notifications asks for.
    var pushKinds: [String] {
        PushRegistration.kinds(questions: shell.settings.notifyQuestions, finished: shell.settings.notifyFinished, errors: shell.settings.notifyErrors)
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
                CnxFeed.FeedScreen(path: $shell.feedPath) { SidebarToolbarItem(sidebar: shell.sidebar) }
            }
            .badge(FeedStore.shared.needsYouCount)
            Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                SettingsScreen(
                    auth: shell.auth,
                    store: shell.store,
                    settings: shell.settings,
                    path: $shell.settingsPath,
                    scrollRequest: shell.settingsScrollTarget,
                    directory: shell.deviceDirectory,
                    inviteToTeam: { shell.invite(to: $0) },
                    saveAppearance: { shell.saveAppearance($0, for: $1) }
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
