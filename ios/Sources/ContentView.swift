import OSLog
import SwiftUI
import Sentry

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "content")

struct ContentView: View {
    private let authManager = AuthManager.shared
    private static let liveTerminalStore = TerminalSidebarRootView.makeLiveStore()
    @State private var terminalStore: TerminalSidebarStore
    private let notificationRouteStore = NotificationRouteStore.shared
    private let uiTestTerminalSetupFixture = UITestConfig.terminalSetupFixtureEnabled
    private let uiTestTerminalInputFixture = UITestConfig.terminalInputFixtureEnabled
    private let uiTestTerminalInboxFixture = UITestConfig.terminalInboxFixtureEnabled
    private let uiTestTerminalDirectFixture = UITestConfig.terminalDirectFixtureEnabled
    private let uiTestTerminalDiscoveredFixture = UITestConfig.terminalDiscoveredFixtureEnabled

    init(terminalStore: TerminalSidebarStore? = nil) {
        _terminalStore = State(wrappedValue: terminalStore ?? Self.liveTerminalStore)
    }

    private static let hasMobileWsSecret: Bool = {
        #if DEBUG
        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"]
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        let path = "\(home)/Library/Application Support/cmux/mobile-ws-secret"
        return FileManager.default.fileExists(atPath: path)
        #else
        return false
        #endif
    }()

    var body: some View {
        Group {
            if uiTestTerminalSetupFixture {
                #if DEBUG
                TerminalSidebarRootView(store: .uiTestSetupFixture())
                #else
                SignInView()
                #endif
            } else if uiTestTerminalInputFixture {
                #if DEBUG
                TerminalSidebarRootView(store: .uiTestInputFixture())
                #else
                SignInView()
                #endif
            } else if uiTestTerminalInboxFixture {
                #if DEBUG
                TerminalSidebarRootView(store: .uiTestInboxFixture())
                #else
                SignInView()
                #endif
            } else if uiTestTerminalDirectFixture {
                #if DEBUG
                TerminalSidebarRootView(store: .uiTestDirectFixture())
                #else
                SignInView()
                #endif
            } else if uiTestTerminalDiscoveredFixture {
                #if DEBUG
                TerminalSidebarRootView(store: .uiTestDiscoveredFixture())
                #else
                SignInView()
                #endif
            } else if Self.hasMobileWsSecret {
                TerminalSidebarRootView(
                    store: terminalStore,
                    routeStore: notificationRouteStore
                )
            } else if authManager.isRestoringSession {
                SessionRestoreView()
            } else if authManager.isAuthenticated {
                TerminalSidebarRootView(
                    store: terminalStore,
                    routeStore: notificationRouteStore
                )
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

struct SettingsView: View {
    private let authManager = AuthManager.shared
    private let notifications = NotificationManager.shared
    @State private var testNotificationAlert: TestNotificationAlert?

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
                                log.error("Failed to send test notification: \(error.localizedDescription, privacy: .public)")
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
                Section("Debug") {
                    NavigationLink("Debug Logs") {
                        DebugLogsView()
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
