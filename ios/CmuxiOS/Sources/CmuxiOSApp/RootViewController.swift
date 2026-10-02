import CmuxHomeCore
import CmuxHomeUI
import CmuxiOSAuth
import CmuxiOSDesign
import UIKit

/// Switches between restoring, sign-in and Home as the auth state changes.
@MainActor
final class RootViewController: UIViewController {
    private let container: AppContainer
    private var current: UIViewController?
    private weak var home: HomeViewController?
    private var shownState: AuthState?

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
        #if DEBUG
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
        becomeFirstResponder()
    }

    private func show(_ state: AuthState) {
        // A new display name or email for the same account keeps the screen.
        guard Self.screenKey(state) != shownState.map(Self.screenKey) else { return }
        shownState = state
        switch state {
        case .restoring:
            install(LaunchPlaceholderViewController())
        case .signedOut:
            container.signedOut()
            install(SignInScreen.make(coordinator: container.auth.coordinator))
        case .signedIn(let account):
            showHome(account: account)
            DebugLaunchTasks.signedIn(container: container)
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
        self.home = home
        let navigation = UINavigationController(rootViewController: home)
        navigation.navigationBar.prefersLargeTitles = true
        install(navigation)
        DebugLaunchTasks.homeShown(store: store, window: view.window)
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
        present(DevMenu.make(options: container.devOptions, presenter: self), animated: true)
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
