import SwiftUI
import UIKit

/// cmux VNC on iOS: a demo of how VNC streaming would feel in the future
/// cmux iOS app, on the same `CmuxVNC` engine the cmux-next Mac app uses.
@main
struct CmuxVNCApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var hosts = HostStore()

    var body: some Scene {
        WindowGroup {
            ConnectionsView()
                .environment(hosts)
                .onAppear {
                    SeedImport().run(into: hosts)
                    Snapshotter().start()
                }
        }
    }
}

/// Owns the orientations the app allows; sessions lock them.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var orientations: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientations
    }

    /// Applies `mask` now, rotating if the current orientation is not in it.
    @MainActor static func lock(_ mask: UIInterfaceOrientationMask) {
        orientations = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                var controller = window.rootViewController
                while let presented = controller?.presentedViewController { controller = presented }
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}
