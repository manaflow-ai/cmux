import SwiftUI

@main
struct CmuxNextApp: App {
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task { await model.launch() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch model.phase {
            case .launching:
                Color(.systemBackground).ignoresSafeArea()
            case .signedOut:
                WelcomeView()
                    .transition(.opacity)
            case .signedIn:
                ShellView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.smooth(duration: 0.35), value: model.phase)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { for host in model.hosts { await host.probe() } } }
        }
    }
}
