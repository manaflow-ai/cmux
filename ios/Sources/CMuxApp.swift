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

}

final class AppDelegate: NSObject, UIApplicationDelegate {
    private static let remoteNotificationLaunchOptionsKey = UIApplication.LaunchOptionsKey(
        rawValue: "UIApplicationLaunchOptionsRemoteNotificationKey"
    )

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationManager.shared
        if let userInfo = launchOptions?[Self.remoteNotificationLaunchOptionsKey] as? [AnyHashable: Any] {
            NotificationManager.shared.handleNotificationUserInfo(userInfo)
        }
        // Seed the push configurator with any already-stored token so
        // TerminalDaemonConnection can configure the daemon before APNs
        // redelivers a token this launch.
        if let storedToken = NotificationTokenStore.shared.load() {
            PushNotificationConfigurator.shared.updateDeviceToken(storedToken)
        }
        Task {
            // Phase 4.3: request permission on launch (will only prompt if
            // status is .notDetermined) then refresh/register.
            await NotificationManager.shared.requestAuthorizationIfNeeded(trigger: .launch)
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
