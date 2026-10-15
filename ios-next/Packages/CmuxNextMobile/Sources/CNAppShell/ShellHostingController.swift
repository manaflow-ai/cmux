#if os(iOS)
import CNDesign
import Observation
import SwiftUI
import UIKit

/// The window's root controller. It owns the status bar: roots request a
/// style with `.cnStatusBarStyle(_:)`, the shells collect it into
/// `AppModel.statusBarStyle`, and this controller applies it.
final class ShellHostingController: UIHostingController<AppRoot> {
    let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(rootView: AppRoot(model: model))
        observeStatusBarStyle()
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        switch model.statusBarStyle {
        case .darkContent: .darkContent
        case .lightContent: .lightContent
        case nil: .default
        }
    }

    private func observeStatusBarStyle() {
        withObservationTracking {
            _ = model.statusBarStyle
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setNeedsStatusBarAppearanceUpdate()
                self.observeStatusBarStyle()
            }
        }
    }
}

/// UIKit scene delegate so the shell owns the root hosting controller (and
/// with it the status bar). The app target's `AppDelegate` returns this class
/// from `configurationForConnecting`.
@objc(CmuxNextSceneDelegate)
public final class CmuxNextSceneDelegate: UIResponder, UIWindowSceneDelegate {
    public var window: UIWindow?
    fileprivate(set) var model: AppModel?

    public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        appShellLog.info("scene willConnect (adopted=\(self.window != nil, privacy: .public)) urls=\(connectionOptions.urlContexts.count, privacy: .public)")
        install(in: windowScene)
        for context in connectionOptions.urlContexts { model?.handleOpenURL(context.url) }
    }

    private func install(in windowScene: UIWindowScene) {
        guard window == nil else { return }
        let model = AppModel.live(bundle: .main)
        self.model = model
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ShellHostingController(model: model)
        window.makeKeyAndVisible()
        self.window = window
    }

    /// Upgrades over a build that used the SwiftUI `App` lifecycle restore
    /// the saved scene session with SwiftUI's scene delegate, which shows a
    /// black window here. Call once from `didFinishLaunching`: any window
    /// scene that connects with a foreign delegate gets this delegate and
    /// the shell's window instead.
    @MainActor
    public static func adoptScenesWithForeignDelegates() {
        routeRestoredSwiftUIScenes()
        recoveryObserver = NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification, object: nil, queue: .main
        ) { note in
            // Delivered on the main queue (`queue: .main`).
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let scene = object as? UIWindowScene else { return }
                adopt(scene)
            }
        }
    }

    @MainActor private static var recoveryObserver: (any NSObjectProtocol)?

    @MainActor
    static func adopt(_ scene: UIWindowScene, urlContexts: Set<UIOpenURLContext> = []) {
        guard !(scene.delegate is CmuxNextSceneDelegate) else { return }
        let delegate = CmuxNextSceneDelegate()
        scene.delegate = delegate
        delegate.install(in: scene)
        for context in urlContexts { delegate.model?.handleOpenURL(context.url) }
        if scene.activationState == .foregroundActive { delegate.sceneDidBecomeActive(scene) }
    }

    /// The restored session's delegate is SwiftUI's `AppSceneDelegate`, and
    /// its `scene(_:willConnectTo:options:)` is the only place the cold-launch
    /// `urlContexts` arrive. Route that one call to `adopt` so a deep link on
    /// the upgrade launch is not dropped. (The notification above remains the
    /// fallback if the class is absent.)
    @MainActor
    private static func routeRestoredSwiftUIScenes() {
        guard let foreign = NSClassFromString("SwiftUI.AppSceneDelegate") else { return }
        let selector = #selector(UIWindowSceneDelegate.scene(_:willConnectTo:options:))
        let block: @convention(block) (AnyObject, UIScene, UISceneSession, UIScene.ConnectionOptions) -> Void = { _, scene, _, options in
            nonisolated(unsafe) let scene = scene
            nonisolated(unsafe) let contexts = options.urlContexts
            MainActor.assumeIsolated {
                guard let windowScene = scene as? UIWindowScene else { return }
                adopt(windowScene, urlContexts: contexts)
            }
        }
        class_replaceMethod(foreign, selector, imp_implementationWithBlock(block), "v@:@@@")
    }

    public func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        for context in contexts { model?.handleOpenURL(context.url) }
    }

    public func sceneDidBecomeActive(_ scene: UIScene) {
        model?.becameActive()
    }
}
#endif
