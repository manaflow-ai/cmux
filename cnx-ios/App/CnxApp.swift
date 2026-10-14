import CnxAuth
import CnxModel
import CnxShell
#if DEBUG
import CnxLive
import CnxTerminal
#endif
import SwiftUI

@main
struct CnxApp: App {
    /// Push registration and notification taps (CnxShell).
    @UIApplicationDelegateAdaptor(CnxAppDelegate.self) private var appDelegate
    @State private var auth: CnxAuthModel

    init() {
        #if !DEBUG
        // Release and Production have no Developer page: remove any developer
        // setting (mock data, a scripted demo, relay only) an earlier Debug
        // or Demo install left in this container, before anything reads them.
        DeveloperOptions.removeStoredValues()
        #endif
        _auth = State(initialValue: CnxAuthModel.live(
            environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier
        ))
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if TerminalFloodBenchRoot.isRequested {
                TerminalFloodBenchRoot()
            } else if TerminalDemoRoot.isRequested || DeveloperOptions.launchDemo == "terminal" {
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
