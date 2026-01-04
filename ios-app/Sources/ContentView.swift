import SwiftUI
import Sentry

struct ContentView: View {
    @StateObject private var authManager = AuthManager.shared

    var body: some View {
        Group {
            if authManager.isAuthenticated {
                MainTabView()
            } else {
                SignInView()
            }
        }
        .animation(.easeInOut, value: authManager.isAuthenticated)
    }
}

struct MainTabView: View {
    var body: some View {
        ConversationListView()
    }
}

struct SettingsView: View {
    @StateObject private var authManager = AuthManager.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let user = authManager.currentUser {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.gray)

                            VStack(alignment: .leading) {
                                Text(user.display_name ?? "User")
                                    .font(.headline)
                                if let email = user.primary_email {
                                    Text(email)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                #if DEBUG
                Section("Debug") {
                    NavigationLink("Convex Test") {
                        ConvexTestView()
                    }
                    Button("Test Sentry Error") {
                        SentrySDK.capture(error: NSError(domain: "dev.cmux.test", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Test error from cmux iOS app"
                        ]))
                    }
                    Button("Test Sentry Crash") {
                        fatalError("Test crash from cmux iOS app")
                    }
                    .foregroundStyle(.red)
                }
                #endif

                Section {
                    Button(role: .destructive) {
                        Task {
                            await authManager.signOut()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Text("Sign Out")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    ContentView()
}
