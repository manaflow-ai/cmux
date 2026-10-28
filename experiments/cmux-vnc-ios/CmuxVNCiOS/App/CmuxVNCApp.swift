import CmuxScreenKitUI
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

/// Sessions lock orientation through CmuxScreenKitUI; iOS asks here.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { ScreenOrientation.shared.allowed }
    }
}
