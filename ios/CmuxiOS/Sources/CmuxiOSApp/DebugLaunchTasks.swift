import CmuxHomeCore
import CmuxiOSAuth
import UIKit

/// DEBUG-only work after sign-in: the dogfood readiness receipt and, on
/// request, the prototype gallery capture. Release builds do nothing.
@MainActor
enum DebugLaunchTasks {
    static func run(container: AppContainer, store: HomeStore, window: UIWindow?) {
        #if DEBUG
        let coordinator = container.auth.coordinator
        let apiBaseURL = container.apiBaseURL
        Task {
            await DogfoodReadinessReceipt.writeIfRequested(coordinator: coordinator, apiBaseURL: apiBaseURL)
        }
        #endif
    }
}
