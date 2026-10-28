public import CmuxChiefVoiceCore
public import UIKit

/// Entry points the app target's thin `@main` delegate calls.
@MainActor
public enum CmuxiOSApplication {
    /// Builds the root view controller for a new window scene.
    public static func makeRootViewController() -> UIViewController {
        RootViewController(container: container)
    }

    /// Call from `application(_:didFinishLaunchingWithOptions:)` so the
    /// notification delegate exists before a cold-start banner tap arrives.
    public static func prepare() { _ = container }

    public static func didRegisterForRemoteNotifications(deviceToken: Data) {
        Task { await container.push.didRegister(token: deviceToken) }
    }

    /// An App Intent (Action Button, Siri, Shortcuts, Control Center) asked
    /// for a Chief call or voice note; it waits until Home is ready.
    public static func handle(_ request: ChiefVoiceRequest) {
        container.chiefCall.handle(request)
    }

    private static let container = AppContainer()
}
