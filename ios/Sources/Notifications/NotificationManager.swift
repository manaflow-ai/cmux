import Foundation
import UIKit
import UserNotifications
import ConvexMobile

@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var isRegisteredForRemoteNotifications = false

    private let convex = ConvexClientManager.shared
    private let tokenStore = NotificationTokenStore.shared
    private var isRequestInFlight = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    var statusLabel: String {
        switch authorizationStatus {
        case .authorized:
            return "Enabled"
        case .denied:
            return "Disabled"
        case .notDetermined:
            return "Not Determined"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Ephemeral"
        @unknown default:
            return "Unknown"
        }
    }

    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    @objc private func handleDidBecomeActive() {
        Task {
            await refreshAuthorizationStatus()
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
        isRegisteredForRemoteNotifications = UIApplication.shared.isRegisteredForRemoteNotifications

        if isAuthorized {
            registerForRemoteNotifications()
        } else {
            await removeTokenIfNeeded()
        }
    }

    func requestAuthorizationIfNeeded(trigger: NotificationRequestTrigger) async {
        if isRequestInFlight {
            return
        }

        await refreshAuthorizationStatus()

        guard authorizationStatus == .notDetermined else {
            if isAuthorized {
                registerForRemoteNotifications()
            }
            return
        }

        isRequestInFlight = true
        defer { isRequestInFlight = false }

        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            if granted {
                registerForRemoteNotifications()
            }
        } catch {
            print("🔔 Notification permission request failed (\(trigger.rawValue)): \(error)")
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }

    func sendTestNotification() async throws {
        await requestAuthorizationIfNeeded(trigger: .settings)
        await refreshAuthorizationStatus()

        guard isAuthorized else {
            throw NotificationTestError.notAuthorized
        }

        await syncTokenIfPossible()

        guard tokenStore.load() != nil else {
            throw NotificationTestError.deviceTokenMissing
        }

        guard convex.isAuthenticated else {
            throw NotificationTestError.notAuthenticated
        }

        let args = PushTokensSendTestArgs(
            title: "cmux test",
            body: "Push notification from cmux"
        )
        let _: PushTokensSendTestReturn = try await convex.client.mutation(
            "pushTokens:sendTest",
            with: args.asDictionary()
        )
    }

    func handleDeviceToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        tokenStore.save(token)
        Task {
            await syncTokenIfPossible()
        }
    }

    func handleRegistrationFailure(_ error: Error) {
        print("🔔 Failed to register for remote notifications: \(error)")
    }

    func syncTokenIfPossible() async {
        await refreshAuthorizationStatus()
        guard isAuthorized else {
            await removeTokenIfNeeded()
            return
        }

        guard convex.isAuthenticated else {
            return
        }

        guard let token = tokenStore.load() else {
            return
        }

        guard let bundleId = Bundle.main.bundleIdentifier else {
            print("🔔 Missing bundle identifier, cannot register push token.")
            return
        }

        let environment: PushTokensUpsertArgsEnvironmentEnum = Environment.current == .development
            ? .development
            : .production
        let deviceId = UIDevice.current.identifierForVendor?.uuidString

        do {
            let args = PushTokensUpsertArgs(
                deviceId: deviceId,
                token: token,
                environment: environment,
                platform: "ios",
                bundleId: bundleId
            )
            let _: PushTokensUpsertReturn = try await convex.client.mutation(
                "pushTokens:upsert",
                with: args.asDictionary()
            )
        } catch {
            print("🔔 Failed to sync push token: \(error)")
        }
    }

    func unregisterFromServer() async {
        guard let token = tokenStore.load() else {
            return
        }

        guard convex.isAuthenticated else {
            tokenStore.clear()
            return
        }

        do {
            let args = PushTokensRemoveArgs(token: token)
            let _: PushTokensRemoveReturn = try await convex.client.mutation(
                "pushTokens:remove",
                with: args.asDictionary()
            )
            tokenStore.clear()
        } catch {
            print("🔔 Failed to remove push token: \(error)")
        }
    }

    private func removeTokenIfNeeded() async {
        guard tokenStore.load() != nil else {
            return
        }
        await unregisterFromServer()
    }

    private func registerForRemoteNotifications() {
        if UIApplication.shared.isRegisteredForRemoteNotifications {
            isRegisteredForRemoteNotifications = true
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .list, .sound, .badge]
    }
}

enum NotificationRequestTrigger: String {
    case createConversation
    case sendMessage
    case settings
}

enum NotificationTestError: Error, LocalizedError {
    case notAuthorized
    case notAuthenticated
    case deviceTokenMissing

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Notifications aren’t enabled for this device."
        case .notAuthenticated:
            return "You need to be signed in to send a test notification."
        case .deviceTokenMissing:
            return "No device token yet. Reopen the app after granting permission."
        }
    }
}
