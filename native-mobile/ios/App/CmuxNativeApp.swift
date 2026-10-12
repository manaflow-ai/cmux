import SwiftUI

@main
struct CmuxNativeApp: App {
    @State private var app = AppModel()
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .task { await app.launch() }
        }
    }
}

/// Launch → sign in → tabs (Sessions, Feed) with Settings from the profile.
struct RootView: View {
    let app: AppModel
    @State private var tab: RootTab = .sessions

    enum RootTab: Hashable { case sessions, feed }

    var body: some View {
        ZStack {
            switch app.phase {
            case .launching:
                LaunchView()
            case .signedOut:
                SignInScreen(app: app).transition(.opacity)
            case .ready:
                tabs.transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: app.phase)
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab(String(localized: "Sessions"), systemImage: "terminal", value: RootTab.sessions) {
                SessionsScreen(app: app)
            }
            Tab(String(localized: "Feed"), systemImage: "bell", value: RootTab.feed) {
                NavigationStack { FeedScreen(app: app) }
            }
            .badge(app.feed.unreadCount)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

/// Matches the launch screen (LaunchBackground + LaunchMark), then fades.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            CmuxMark().frame(width: 72, height: 72)
        }
    }
}
