import SwiftUI

@main
struct CmuxNextApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.launch() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

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
    }
}
