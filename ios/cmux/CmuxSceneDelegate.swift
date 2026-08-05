import UIKit
import cmuxFeature

/// UIKit window-scene owner. It forwards lifecycle and URLs into the native
/// cmux root, keeping process analytics separate from per-scene shell state.
@MainActor
final class CmuxSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var rootController: CMUXMobileRootViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let controller = CmuxApplication.makeRootViewController()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        self.window = window
        rootController = controller
        window.makeKeyAndVisible()

        for context in connectionOptions.urlContexts {
            controller.open(context.url)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        CmuxApplication.root.handleScenePhase(.active)
        rootController?.sceneDidBecomeActive()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        CmuxApplication.root.handleScenePhase(.inactive)
        rootController?.sceneWillResignActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        CmuxApplication.root.handleScenePhase(.background)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            rootController?.open(context.url)
        }
    }
}
