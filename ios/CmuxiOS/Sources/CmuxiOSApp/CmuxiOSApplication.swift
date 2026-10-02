public import UIKit

/// Entry points the app target's thin `@main` delegate calls.
@MainActor
public enum CmuxiOSApplication {
    /// Builds the root view controller for a new window scene.
    public static func makeRootViewController() -> UIViewController {
        RootViewController(container: container)
    }

    private static let container = AppContainer()
}
