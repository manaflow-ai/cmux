import SwiftUI
import Sentry
import UIKit
import UserNotifications

@main
struct CMuxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        if UITestConfig.mockDataEnabled {
            let allowAnimations = {
                let value = ProcessInfo.processInfo.environment["CMUX_UITEST_ALLOW_ANIMATIONS"] ?? "0"
                return value == "1" || value.lowercased() == "true"
            }()
            if !allowAnimations {
                UIView.setAnimationsEnabled(false)
            }
            resetDebugInputDefaults()
        }
        CrashReporter.install()
        DebugLog.add("App init. uiTest=\(UITestConfig.mockDataEnabled)")
        #endif
        SentrySDK.start { options in
            options.dsn = "https://834d19a3077c4adbff534dca1e93de4f@o4507547940749312.ingest.us.sentry.io/4510604800491520"
            options.debug = false

            #if DEBUG
            options.environment = "development"
            #elseif BETA
            options.environment = "beta"
            #else
            options.environment = "production"
            #endif

            options.tracesSampleRate = 1.0
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    #if DEBUG
    private func resetDebugInputDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: DebugSettingsKeys.showChatOverlays)
        defaults.set(false, forKey: DebugSettingsKeys.showChatInputTuning)
        defaults.set(0.0, forKey: "debug.input.bottomInsetSingleExtra")
        defaults.set(4.0, forKey: "debug.input.bottomInsetMultiExtra")
        defaults.set(4.0, forKey: "debug.input.topInsetMultiExtra")
        defaults.set(-12.0, forKey: "debug.input.micOffset")
        defaults.set(-4.0, forKey: "debug.input.sendOffset")
        defaults.set(1.0, forKey: "debug.input.sendXOffset")
        defaults.set(34.0, forKey: "debug.input.barYOffset")
        defaults.set(10.0, forKey: "debug.input.bottomMessageGap")
        defaults.set(false, forKey: "debug.input.isMultiline")
    }
    #endif
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationManager.shared
        Task {
            await NotificationManager.shared.refreshAuthorizationStatus()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationManager.shared.handleDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationManager.shared.handleRegistrationFailure(error)
    }
}
