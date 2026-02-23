import SwiftUI
import Sentry

struct ContentView: View {
    @StateObject private var authManager = AuthManager.shared
    private let uiTestDirectChat: Bool = {
        ProcessInfo.processInfo.environment["CMUX_UITEST_DIRECT_CHAT"] == "1"
    }()
    private let uiTestChatView: Bool = {
        ProcessInfo.processInfo.environment["CMUX_UITEST_CHAT_VIEW"] == "1"
    }()
    private let uiTestConversationId: String = {
        ProcessInfo.processInfo.environment["CMUX_UITEST_CONVERSATION_ID"] ?? "uitest_conversation_claude"
    }()
    private let uiTestProviderId: String = {
        ProcessInfo.processInfo.environment["CMUX_UITEST_PROVIDER_ID"] ?? "claude"
    }()

    var body: some View {
        Group {
            if uiTestChatView {
                ChatFix1MainView(conversationId: uiTestConversationId, providerId: uiTestProviderId)
                    .ignoresSafeArea()
            } else if uiTestDirectChat {
                #if DEBUG
                InputBarUITestHarnessView()
                #else
                SignInView()
                #endif
            } else if authManager.isRestoringSession {
                SessionRestoreView()
            } else if authManager.isAuthenticated {
                MainTabView()
            } else {
                SignInView()
            }
        }
    }
}

struct SessionRestoreView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Restoring session...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("auth.restoring")
    }
}

struct MainTabView: View {
    var body: some View {
        ConversationListView()
    }
}

#if DEBUG
struct InputBarUITestHarnessView: View {
    var body: some View {
        InputBarUITestHarnessWrapper()
            .ignoresSafeArea()
    }
}

private struct InputBarUITestHarnessWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> InputBarUITestHarnessViewController {
        InputBarUITestHarnessViewController()
    }

    func updateUIViewController(_ uiViewController: InputBarUITestHarnessViewController, context: Context) {}
}

private final class InputBarUITestHarnessViewController: UIViewController {
    private var inputBarVC: DebugInputBarViewController!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        inputBarVC = DebugInputBarViewController()
        inputBarVC.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(inputBarVC)
        view.addSubview(inputBarVC.view)
        inputBarVC.didMove(toParent: self)

        NSLayoutConstraint.activate([
            inputBarVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBarVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBarVC.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
    }
}
#endif

struct SettingsView: View {
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var notifications = NotificationManager.shared
    @State private var testNotificationAlert: TestNotificationAlert?
    #if DEBUG
    @AppStorage(DebugSettingsKeys.showChatOverlays) private var showChatOverlays = false
    @AppStorage(DebugSettingsKeys.showChatInputTuning) private var showChatInputTuning = false
    #endif

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
                                Text(user.displayName ?? "User")
                                    .font(.headline)
                                if let email = user.primaryEmail {
                                    Text(email)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Notifications") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(notifications.statusLabel)
                            .foregroundStyle(.secondary)
                    }

                    if notifications.authorizationStatus == .notDetermined {
                        Button("Enable Notifications") {
                            Task {
                                await notifications.requestAuthorizationIfNeeded(trigger: .settings)
                            }
                        }
                    } else {
                        Button("Open System Settings") {
                            notifications.openSystemSettings()
                        }
                    }

                    #if DEBUG
                    Button("Send Test Notification") {
                        Task {
                            do {
                                try await notifications.sendTestNotification()
                                testNotificationAlert = TestNotificationAlert(
                                    title: "Test Notification Sent",
                                    message: "Check your device for a push notification."
                                )
                            } catch {
                                print("🔔 Failed to send test notification: \(error)")
                                SentrySDK.capture(error: error)
                                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                                testNotificationAlert = TestNotificationAlert(
                                    title: "Test Notification Failed",
                                    message: message
                                )
                            }
                        }
                    }
                    #endif
                }

                #if DEBUG
                Section("External Accounts") {
                    NavigationLink("OpenAI Codex") {
                        CodexOAuthView()
                    }
                }

                Section("Debug") {
                    Toggle("Show chat debug overlays", isOn: $showChatOverlays)
                    Toggle("Show input tuning panel", isOn: $showChatInputTuning)
                    NavigationLink("Chat Keyboard Approaches") {
                        ChatDebugMenu()
                    }
                    NavigationLink("Debug Logs") {
                        DebugLogsView()
                    }
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
            .alert(item: $testNotificationAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .task {
                await notifications.refreshAuthorizationStatus()
            }
        }
    }
}

struct TestNotificationAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

#Preview {
    ContentView()
}
