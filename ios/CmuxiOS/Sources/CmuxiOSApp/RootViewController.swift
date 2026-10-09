import CmuxHomeCore
import CmuxHomeUI
import CmuxiOSAuth
import CmuxiOSDesign
import CmuxiOSPlatform
import CmuxiOSPlatformUI
import CmuxiOSOnboarding
import CmuxiOSOnboardingCore
import CmuxiOSSettingsCore
import CmuxiOSShell
import CmuxiOSTerminal
import UIKit

/// Switches between restoring, onboarding, sign-in and the signed-in shell
/// (Home plus the feature tabs) as the auth state changes. One onboarding
/// controller lives across signed-out and signed-in until it finishes.
@MainActor
final class RootViewController: UIViewController {
    let container: AppContainer
    private var current: UIViewController?
    private weak var home: HomeViewController?
    private(set) weak var shell: ShellRootController?
    /// The current shell's feature entry points (routes and search use them).
    var shellFeatures: ShellFeatures?
    let searchOpener = AppSearchOpener()
    private var shellAccount: SignedInAccount?
    private var shownState: AuthState?
    private var toastWindow: ToastWindow?
    private var whatsNewChecked = false
    private var onboarding: OnboardingViewController?
    private var onboardingDecided = false
    /// Set while Erase All Data runs and after: auth changes no longer
    /// rebuild the UI, and the erased screen stays until the app closes.
    private var erased = false
    /// The signed-out guest shell is on screen (deferred sign-in).
    private var isGuestShell = false

    init(container: AppContainer) {
        self.container = container
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HomePalette.background
        container.auth.onChange = { [weak self] state in self?.show(state) }
        container.devOptions.onChange = { [weak self] options in self?.home?.apply(options) }
        container.onUpdateRequiredChange = { [weak self] requirement in self?.home?.updateRequired = requirement }
        container.flags.onChange = { [weak self] in self?.applyFlags() }
        container.sourceModes.onChange = { [weak self] in self?.rebuildShell() }
        container.onDemoChange = { [weak self] in self?.rebuildShell() }
        container.feedResponder.openItem = { [weak container] item in
            // The router opens the Feed tab on the item (deferred until
            // signed in); the Feed screen parks it until its mirror has it.
            container?.router.open(.feed(item: item))
        }
        container.router.install { [weak self] route in self?.handle(route) }
        container.onContinueWithoutAccount = { [weak self] in self?.chooseGuest() }
        container.router.onNeedsAccount = { [weak container] _ in
            container?.toasts.show(Toast(.info, String(
                localized: "guest.route.needsAccount",
                defaultValue: "Sign in to open this. SSH hosts work without an account.", bundle: .module)))
        }
        container.router.onUnrecognized = { [weak container] _ in
            container?.toasts.show(Toast(.warning, String(
                localized: "platform.link.unrecognized",
                defaultValue: "This link needs a newer version of cmux.", bundle: .module)))
        }
        #if DEBUG
        if let minimum = ProcessInfo.processInfo.environment["CMUX_IOS_PREVIEW_UPDATE_REQUIRED"] {
            // DEV preview (simulator screenshots): the update-required banner
            // as a too-old refusal shows it; an empty value names no version.
            container.setUpdateRequired(HomeUpdateRequired(minimumVersion: minimum.isEmpty ? nil : minimum))
        }
        if ProcessInfo.processInfo.environment["CMUX_IOS_HOME_PREVIEW"] == "1" {
            // DEV preview: Home on the mock owner without an account, for
            // simulator screenshots of the prototypes. The mock needs no sign-in.
            showHome(account: SignedInAccount(userID: "preview", email: nil, displayName: "Preview"))
            return
        }
        #endif
        container.auth.start()
        show(container.auth.state)
    }

    override var canBecomeFirstResponder: Bool { true }

    /// Keep universal search available from every shell tab, including the
    /// SwiftUI settings and hosts screens whose navigation controllers can
    /// otherwise become the first responder before the shell tab controller.
    override var keyCommands: [UIKeyCommand]? {
        guard shell != nil else { return super.keyCommands }
        let search = UIKeyCommand(title: String(localized: "Search"),
                                   action: #selector(performShellSearch),
                                   input: "k", modifierFlags: .command)
        search.discoverabilityTitle = String(localized: "Search")
        return (super.keyCommands ?? []) + [search]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(performShellSearch) { return shell != nil }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func performShellSearch() { openSearch(query: nil) }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if toastWindow == nil, let scene = view.window?.windowScene {
            toastWindow = ToastWindow(scene: scene, center: container.toasts)
        }
        // Keep a root-level Cmd-K responder even when a SwiftUI shell screen
        // owns the focused responder. Home's own Cmd-F/Cmd-N commands remain
        // discoverable through the child responder chain.
        becomeFirstResponder()
        presentWhatsNewIfNeeded()
    }

    private func show(_ state: AuthState) {
        guard !erased else { return }
        // A new display name or email for the same account keeps the screen.
        guard Self.screenKey(state) != shownState.map(Self.screenKey) else { return }
        shownState = state
        switch state {
        case .restoring:
            container.router.setAccountReady(false)
            install(LaunchPlaceholderViewController())
        case .signedOut:
            container.router.setAccountReady(false)
            shellAccount = nil
            shellFeatures = nil
            container.signedOut()
            if container.isGuest {
                showGuestShell()
            } else if presentsOnboarding(signedIn: false) {
                showOnboarding(signedIn: false)
            } else {
                showSignIn()
            }
        case .signedIn(let account):
            // Signing in ends guest use; what was made signed out is offered for sync.
            let wasGuest = container.guestMode.isChosen || isGuestShell
            container.guestMode.clear()
            isGuestShell = false
            let onboards = presentsOnboarding(signedIn: true)
            // Onboarding primes the notifications prompt; a user who chose
            // Not Now there is not asked again at the next launch.
            let declined = container.onboardingStore.load()?.outcomes[.notifications] == .skipped
            container.signedIn(account: account, requestPushPermission: !onboards && !declined)
            DebugLaunchTasks.signedIn(container: container)
            if onboards {
                showOnboarding(signedIn: true)
            } else {
                showHome(account: account)
            }
            if wasGuest { offerGuestHostsSync() }
        }
    }

    // MARK: - Deferred sign-in (e5-extras.md section 5)

    private func showSignIn() {
        install(SignInScreen.make(coordinator: container.auth.coordinator,
                                  onContinueWithoutAccount: { [weak self] in self?.chooseGuest() }))
    }

    /// "Use SSH Without an Account": stored, then the guest shell. A running
    /// onboarding keeps its place and resumes after sign-in.
    private func chooseGuest() {
        guard !erased, case .signedOut = container.auth.state else { return }
        container.guestMode.choose()
        showGuestShell()
    }

    private func showGuestShell() {
        let shell = ShellComposition.makeGuestShell(
            container: container,
            signIn: { [weak self] in self?.leaveGuest() },
            eraseAllData: { [weak self] in await self?.eraseAllData() ?? EraseReport() })
        self.shell = shell
        shellFeatures = nil
        isGuestShell = true
        install(shell)
        container.router.setAccess(.guest)
        presentWhatsNewIfNeeded()
    }

    /// Settings > Sign In from the guest shell: back to the sign-in screen,
    /// which offers the guest entry again.
    private func leaveGuest() {
        container.guestMode.clear()
        isGuestShell = false
        shell = nil
        container.router.setAccess(.none)
        showSignIn()
    }

    /// After a guest signs in: hosts added signed out can join the account.
    private func offerGuestHostsSync() {
        Task { [weak self] in
            guard let self else { return }
            let pending = await container.pendingGuestHosts()
            guard !pending.isEmpty else {
                await container.adoptGuestHosts([])
                return
            }
            let alert = UIAlertController(
                title: String(localized: "guest.sync.title", defaultValue: "Sync SSH Hosts?", bundle: .module),
                message: String(format: String(
                    localized: "guest.sync.message",
                    defaultValue: "%lld hosts were added on this iPhone without an account. Add them to your account so your other devices get them? Keys and passwords stay on this iPhone.",
                    bundle: .module), pending.count),
                preferredStyle: .alert)
            let ids = pending.map(\.id)
            alert.addAction(UIAlertAction(title: String(localized: "guest.sync.keep", defaultValue: "Keep on This iPhone", bundle: .module),
                                          style: .cancel) { [weak self] _ in
                Task { await self?.container.guestHostsLedger.clear() }
            })
            alert.addAction(UIAlertAction(title: String(localized: "guest.sync.confirm", defaultValue: "Sync to Account", bundle: .module),
                                          style: .default) { [weak self] _ in
                Task { await self?.container.adoptGuestHosts(ids) }
            })
            presentOnTop(alert)
        }
    }

    // MARK: - Onboarding

    /// Decided once per launch from the stored progress and auth; afterwards
    /// only a running onboarding keeps presenting.
    private func presentsOnboarding(signedIn: Bool) -> Bool {
        if let onboarding { return !onboarding.model.isFinished }
        guard !onboardingDecided else { return false }
        onboardingDecided = true
        return container.onboardingPolicy.shouldPresent(stored: container.onboardingStore.load(), isSignedIn: signedIn)
    }

    private func showOnboarding(signedIn: Bool) {
        if let onboarding {
            onboarding.model.setSignedIn(signedIn)
            if current !== onboarding { install(onboarding) }
            return
        }
        let model = OnboardingComposition.firstRun(container: container, isSignedIn: signedIn)
        let controller = OnboardingViewController(model: model)
        model.onFinish = { [weak self] _ in self?.onboardingFinished() }
        onboarding = controller
        install(controller)
    }

    private func onboardingFinished() {
        onboarding = nil
        if case .signedIn(let account) = container.auth.state {
            showHome(account: account)
        } else if container.isGuest {
            showGuestShell()
        } else {
            showSignIn()
        }
    }

    /// Settings > Erase All Data: wipes, then shows the final screen.
    func eraseAllData() async -> EraseReport {
        erased = true
        container.router.setAccountReady(false)
        let report = await container.eraseAllData()
        if presentedViewController != nil { dismiss(animated: true) }
        shell = nil
        shellFeatures = nil
        install(ErasedViewController(report: report))
        return report
    }

    /// Settings > Replay Welcome Tour: the tour in memory, full screen.
    private func presentReplay() {
        let model = OnboardingComposition.replay(container: container)
        let controller = OnboardingViewController(model: model)
        controller.modalPresentationStyle = .fullScreen
        model.onFinish = { [weak controller] _ in controller?.dismiss(animated: true) }
        var presenter: UIViewController = self
        while let next = presenter.presentedViewController { presenter = next }
        presenter.present(controller, animated: true)
    }

    private static func screenKey(_ state: AuthState) -> String {
        switch state {
        case .restoring: "restoring"
        case .signedOut: "signedOut"
        case .signedIn(let account): "signedIn:" + account.userID
        }
    }

    private func showHome(account: SignedInAccount) {
        let store = container.homeStore(for: account)
        let home = HomeViewController(store: store, options: container.devOptions.options)
        home.updateRequired = container.updateRequired
        self.home = home
        let navigation = UINavigationController(rootViewController: home)
        navigation.navigationBar.prefersLargeTitles = true
        searchOpener.root = self
        let (shell, features) = ShellComposition.makeShell(
            container: container, account: account, home: navigation, searchOpener: searchOpener,
            replayTour: { [weak self] in self?.presentReplay() },
            eraseAllData: { [weak self] in await self?.eraseAllData() ?? EraseReport() }
        )
        shell.onSearchCommand = { [weak self] in self?.openSearch(query: nil) }
        self.shell = shell
        shellFeatures = features
        shellAccount = account
        install(shell)
        ShellComposition.selectLaunchTab(in: shell)
        DebugLaunchTasks.homeShown(store: store, window: view.window)
        // The shell is on screen: deferred links deliver, What's New may show.
        container.router.setAccountReady(true)
        presentWhatsNewIfNeeded()
        #if DEBUG
        if let kind = ProcessInfo.processInfo.environment["CMUX_IOS_OPEN_CONVERSATION"] {
            home.debugOpenFirstConversation(kind: kind, tapback: ProcessInfo.processInfo.environment["CMUX_IOS_OPEN_TAPBACK"])
        }
        if let query = ProcessInfo.processInfo.environment["CMUX_IOS_OPEN_SEARCH"] {
            let index = ProcessInfo.processInfo.environment["CMUX_IOS_OPEN_SEARCH_HIT"].flatMap { Int($0) } ?? 0
            home.debugOpenSearchHit(query: query, index: index)
        }
        if ProcessInfo.processInfo.environment["CMUX_IOS_PREVIEW_OFFLINE"] == "1",
           let mock = store.source as? MockHomeSource {
            // DEV preview (simulator screenshots): the mock owner drops its
            // connection, so the offline banner shows (with any other banner).
            Task { await mock.setOnline(false) }
        }
        if ProcessInfo.processInfo.environment["CMUX_IOS_TERMINAL_PREVIEW"] == "1" {
            let terminal = DevTerminal.make()
            navigation.pushViewController(terminal, animated: false)
            DevTerminal.captureDiagnostics(terminal)
        }
        if let workload = ProcessInfo.processInfo.environment["CMUX_IOS_TERMINAL_BENCH"] {
            navigation.pushViewController(DevTerminal.makeBench(workload), animated: false)
        }
        #endif
    }

    /// The post-update What's New sheet, once per process after sign-in.
    private func presentWhatsNewIfNeeded() {
        guard !whatsNewChecked, shell != nil, view.window != nil, presentedViewController == nil else { return }
        let environment = ProcessInfo.processInfo.environment
        guard !environment.keys.contains(where: { $0.hasPrefix("CMUX_UITEST_") }),
              environment["CMUX_IOS_HOME_PREVIEW"] == nil else { return }
        whatsNewChecked = true
        if let sheet = PlatformComposition.launchWhatsNew() { present(sheet, animated: true) }
    }

    private func applyFlags() {
        let tabs = isGuestShell ? ShellComposition.guestTabs : container.flags.visibleTabs
        shell?.setTabs(tabs, sidebar: container.flags.isEnabled(.iPadSidebar))
    }

    /// A seam mode changed: rebuild the seams and the shell. Home's store is
    /// kept by the container, so Home keeps its state.
    private func rebuildShell() {
        container.dropFeatureSources()
        guard let account = shellAccount, shell != nil else { return }
        let selected = shell?.selectedShellTab
        showHome(account: account)
        if let selected { shell?.select(selected) }
    }

    private func install(_ next: UIViewController) {
        let previous = current
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        next.view.alpha = previous == nil ? 1 : 0
        view.addSubview(next.view)
        next.didMove(toParent: self)
        current = next
        guard let previous else { return }
        previous.willMove(toParent: nil)
        HomeMotion.animate({
            next.view.alpha = 1
            previous.view.alpha = 0
        }, completion: { _ in
            previous.view.removeFromSuperview()
            previous.removeFromParent()
        })
    }

    #if DEBUG
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else { return super.motionEnded(motion, with: event) }
        present(DevMenu.make(container: container, presenter: self), animated: true)
    }
    #endif
}

/// Shown while the stored session restores (no spinner: it is usually instant).
@MainActor
final class LaunchPlaceholderViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HomePalette.background
    }
}
