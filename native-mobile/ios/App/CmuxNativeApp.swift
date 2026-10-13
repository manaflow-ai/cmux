import SwiftUI

@main
struct CmuxNativeApp: App {
    @State private var app = AppModel()
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                // Sign-in is always dark (like Claude/ChatGPT/Grok launch screens).
                .preferredColorScheme(app.phase != .ready ? .dark : appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .appLock()
                .pushNotifications(app: app)
                .task { await app.launch() }
                .onChange(of: scenePhase) { _, phase in
                    // Back from the background (not a Control Center pull):
                    // check the link at once and catch up.
                    if phase == .background {
                        wasInBackground = true
                    } else if phase == .active, wasInBackground {
                        wasInBackground = false
                        Task { await app.becameActive() }
                    }
                }
        }
    }
}

/// Launch → sign in → sidebar (Home, Feed, terminals) with Settings from
/// the account menu, like the desktop cmux-next sidebar.
struct RootView: View {
    let app: AppModel

    var body: some View {
        ZStack {
            switch app.phase {
            case .launching:
                LaunchView()
            case .signedOut:
                SignInScreen(app: app).transition(.opacity)
            case .ready:
                SidebarRoot(app: app).transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: app.phase)
    }
}

/// Matches the launch screen (LaunchBackground + LaunchMark), then fades.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            CmuxMark().frame(width: 72, height: 72)
                .accessibilityLabel(String(localized: "cmux"))
        }
    }
}
