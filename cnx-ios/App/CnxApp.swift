import CnxAuth
import CnxModel
import CnxShell
import SwiftUI

@main
struct CnxApp: App {
    @State private var auth = CnxAuthModel.live(
        environment: ProcessInfo.processInfo.environment,
        bundleIdentifier: Bundle.main.bundleIdentifier
    )

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth, store: .mock())
        }
    }
}
