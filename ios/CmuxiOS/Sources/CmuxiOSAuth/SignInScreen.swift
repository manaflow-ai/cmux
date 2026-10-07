public import CmuxAuthRuntime
import SwiftUI
public import UIKit

/// The kept sign-in flow (email code, OAuth providers, restore status) as a
/// UIKit view controller for the new app's root flow.
@MainActor
public enum SignInScreen {
    public static func make(coordinator: AuthCoordinator) -> UIViewController {
        let controller = UIHostingController(rootView: SignInView().environment(coordinator))
        controller.view.backgroundColor = .systemBackground
        return controller
    }

    /// The same flow without its standalone chrome (no navigation stack or
    /// header art), for hosts that supply their own title, like onboarding.
    public static func makeEmbedded(coordinator: AuthCoordinator) -> UIViewController {
        let controller = UIHostingController(rootView: SignInView(usesStandaloneChrome: false).environment(coordinator))
        controller.view.backgroundColor = .clear
        return controller
    }
}
