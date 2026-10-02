import CmuxHomeCore
import CmuxiOSAuth
import UIKit

/// DEBUG-only launch work: the dogfood readiness receipt after sign-in and,
/// on request (`CMUX_IOS_GALLERY=1`), the prototype gallery capture into
/// `Library/Caches/cmux-gallery`. Release builds do nothing.
@MainActor
enum DebugLaunchTasks {
    static func signedIn(container: AppContainer) {
        #if DEBUG
        let coordinator = container.auth.coordinator
        let apiBaseURL = container.apiBaseURL
        Task {
            await DogfoodReadinessReceipt.writeIfRequested(coordinator: coordinator, apiBaseURL: apiBaseURL)
        }
        #endif
    }

    static func homeShown(store: HomeStore, window: UIWindow?) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CMUX_IOS_GALLERY"] == "1", let window else { return }
        GalleryRunner.run(store: store, window: window)
        #endif
    }
}
