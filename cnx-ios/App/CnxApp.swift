import CnxAuth
import CnxModel
import CnxShell
import CnxVoice
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
    @Environment(\.scenePhase) private var scenePhase

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
            Group {
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
            .modifier(ChiefCallCover(
                controller: ChiefVoice.controller,
                scenePhase: scenePhase,
                accountID: auth.isSignedIn ? auth.user?.id : nil
            ))
        }
    }
}

/// The Action Button / Shortcuts Chief call over every root (ChiefVoiceIntents.swift).
private struct ChiefCallCover: ViewModifier {
    let controller: ChiefVoiceController
    let scenePhase: ScenePhase
    let accountID: String?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: Binding(
                get: { controller.presented != nil },
                set: { if !$0 { controller.dismiss() } }
            )) {
                ChiefCallScreen(controller: controller)
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                // Notes an earlier call saved go out when the app comes back.
                if phase == .active { Task { await controller.drainOutbox() } }
            }
            .task(id: accountID) {
                await controller.selectAccount(accountID)
            }
    }
}

#if DEBUG
import CnxTransport

/// Keeps the Rust link linked into debug builds so FFI breakage shows at build time.
private let linkDialerProbe: any MacLinkDialer = FFIMacLinkDialer()
#endif
