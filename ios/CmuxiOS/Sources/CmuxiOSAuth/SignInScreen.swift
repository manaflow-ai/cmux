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
}
