import CmuxHomeCore
import CmuxHomeUI
import CmuxiOSAuth
import CmuxiOSDesign
import CmuxiOSPlatform
import CmuxiOSPlatformUI
import CmuxiOSShell
import CmuxiOSTerminal
import UIKit

/// Switches between restoring, sign-in and the signed-in shell (Home plus
/// the feature tabs) as the auth state changes.
@MainActor
final class RootViewController: UIViewController {
    let container: AppContainer
    private var current: UIViewController?
    private weak var home: HomeViewController?
    private(set) weak var shell: ShellRootController?
    private var shellAccount: SignedInAccount?
    private var shownState: AuthState?
    private var toastWindow: ToastWindow?

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
        container.feedResponder.openItem = { [weak container] item in
            // The Feed tab owns item navigation once lane C6 lands; the
            // router opens the tab (deferred until signed in).
            container?.router.open(.feed(item: item))
        }
        container.router.install { [weak self] route in self?.handle(route) }
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if toastWindow == nil, let scene = view.window?.windowScene {
            toastWindow = ToastWindow(scene: scene, center: container.toasts)
        }
        // The shake gesture (DEV menu) reaches this controller from any first
        // responder below it; take first responder only while no Home screen
        // does, so Home's key commands (Cmd-F, Cmd-N, Esc) stay in the chain.
        if home == nil { becomeFirstResponder() }
    }

    private func show(_ state: AuthState) {
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
            container.signedOut()
            install(SignInScreen.make(coordinator: container.auth.coordinator))
        case .signedIn(let account):
            showHome(account: account)
            container.signedIn(account: account)
            DebugLaunchTasks.signedIn(container: container)
            container.router.setAccountReady(true)
        }
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
        let shell = ShellComposition.makeShell(container: container, account: account, home: navigation)
        self.shell = shell
        shellAccount = account
        install(shell)
        ShellComposition.selectLaunchTab(in: shell)
        DebugLaunchTasks.homeShown(store: store, window: view.window)
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
        #endif
    }

    private func applyFlags() {
        shell?.setTabs(container.flags.visibleTabs, sidebar: container.flags.isEnabled(.iPadSidebar))
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
