import CnxAuth
import CnxModel
import CnxShell
#if DEBUG
import CnxTerminal
#endif
import SwiftUI

@main
struct CnxApp: App {
    @State private var auth = CnxAuthModel.live(
        environment: ProcessInfo.processInfo.environment,
        bundleIdentifier: Bundle.main.bundleIdentifier
    )

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if TerminalDemoRoot.isRequested || DeveloperOptions.launchDemo == "terminal" {
                TerminalDemoRoot()
            } else {
                RootView(auth: auth, store: .mock())
            }
            #else
            // Release and Production: no sample data; live data fills it once signed in.
            RootView(auth: auth, store: AppStore(teams: [], activeTeamID: "", workspaces: [], feed: []))
            #endif
        }
    }
}

#if DEBUG
import CnxTransport

/// Keeps the Rust link linked into debug builds so FFI breakage shows at build time.
private let linkDialerProbe: any MacLinkDialer = FFIMacLinkDialer()
#endif
