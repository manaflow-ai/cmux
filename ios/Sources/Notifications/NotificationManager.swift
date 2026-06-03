import Foundation
import OSLog
import UIKit
import UserNotifications

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "notifications")

@MainActor
protocol NotificationPushSyncing {
    var isAuthenticated: Bool { get }
    func sendTestPush(title: String, body: String) async throws
    func upsertPushToken(
        token: String,
        environment: MobilePushEnvironment,
        platform: String,
        bundleId: String,
        deviceId: String?
    ) async throws
    func removePushToken(token: String) async throws
}

@MainActor
struct LiveNotificationPushSyncer: NotificationPushSyncing {
    private let authManager: AuthManager
    private let routeClient: MobilePushRouteClient

    init(
        authManager: AuthManager? = nil,
        routeClient: MobilePushRouteClient? = nil
    ) {
        let resolvedAuthManager = authManager ?? AuthManager.shared
        self.authManager = resolvedAuthManager
        self.routeClient = routeClient ?? MobilePushRouteClient(authManager: resolvedAuthManager)
    }

    var isAuthenticated: Bool {
        authManager.isAuthenticated
    }

    func sendTestPush(title: String, body: String) async throws {
        _ = try await routeClient.sendTestPush(title: title, body: body)
    }

    func upsertPushToken(
        token: String,
        environment: MobilePushEnvironment,
        platform: String,
        bundleId: String,
        deviceId: String?
    ) async throws {
        try await routeClient.upsertPushToken(
            token: token,
            environment: environment,
            platform: platform,
            bundleId: bundleId,
            deviceId: deviceId
        )
    }

    func removePushToken(token: String) async throws {
        try await routeClient.removePushToken(token: token)
    }
}

@MainActor
protocol NotificationSystemHandling {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    var isRegisteredForRemoteNotifications: Bool { get }
    func registerForRemoteNotifications()
    func openSettings()
}

@MainActor
struct LiveNotificationSystem: NotificationSystemHandling {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }

    var isRegisteredForRemoteNotifications: Bool {
        UIApplication.shared.isRegisteredForRemoteNotifications
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }
}

@MainActor
protocol NotificationDeviceInfoProviding {
    var bundleIdentifier: String? { get }
    var vendorIdentifier: String? { get }
}

@MainActor
struct LiveNotificationDeviceInfo: NotificationDeviceInfoProviding {
    var bundleIdentifier: String? {
        Bundle.main.bundleIdentifier
    }

    var vendorIdentifier: String? {
        UIDevice.current.identifierForVendor?.uuidString
    }
}

protocol NotificationPermissionRequestPolicy {
    func shouldRequestAuthorization(trigger: NotificationRequestTrigger) -> Bool
}

struct LiveNotificationPermissionRequestPolicy: NotificationPermissionRequestPolicy {
    private let runsOnSimulator: Bool

    init(runsOnSimulator: Bool = Self.defaultRunsOnSimulator) {
        self.runsOnSimulator = runsOnSimulator
    }

    func shouldRequestAuthorization(trigger: NotificationRequestTrigger) -> Bool {
        !(runsOnSimulator && trigger == .launch)
    }

    private static var defaultRunsOnSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
}

@MainActor
@Observable
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var isRegisteredForRemoteNotifications = false

    private let pushSyncer: NotificationPushSyncing
    private let tokenStore: NotificationTokenStoring
    private let routeStore: NotificationRouteStore
    private let system: NotificationSystemHandling
    private let deviceInfo: NotificationDeviceInfoProviding
    private let permissionRequestPolicy: NotificationPermissionRequestPolicy
    private var isRequestInFlight = false

    private override init() {
        self.pushSyncer = LiveNotificationPushSyncer()
        self.tokenStore = NotificationTokenStore.shared
        self.routeStore = .shared
        self.system = LiveNotificationSystem()
        self.deviceInfo = LiveNotificationDeviceInfo()
        self.permissionRequestPolicy = LiveNotificationPermissionRequestPolicy()
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    init(
        pushSyncer: NotificationPushSyncing,
        tokenStore: NotificationTokenStoring,
        routeStore: NotificationRouteStore,
        system: NotificationSystemHandling,
        deviceInfo: NotificationDeviceInfoProviding,
        permissionRequestPolicy: NotificationPermissionRequestPolicy = LiveNotificationPermissionRequestPolicy(),
        observeDidBecomeActive: Bool
    ) {
        self.pushSyncer = pushSyncer
        self.tokenStore = tokenStore
        self.routeStore = routeStore
        self.system = system
        self.deviceInfo = deviceInfo
        self.permissionRequestPolicy = permissionRequestPolicy
        super.init()
        if observeDidBecomeActive {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }
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
        authorizationStatus = await system.authorizationStatus()
        isRegisteredForRemoteNotifications = system.isRegisteredForRemoteNotifications

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

        guard permissionRequestPolicy.shouldRequestAuthorization(trigger: trigger) else {
            return
        }

        isRequestInFlight = true
        defer { isRequestInFlight = false }

        do {
            let granted = try await system.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            if granted {
                registerForRemoteNotifications()
            }
        } catch {
            log.error("Notification permission request failed (\(trigger.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    func openSystemSettings() {
        system.openSettings()
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

        guard pushSyncer.isAuthenticated else {
            throw NotificationTestError.notAuthenticated
        }

        try await pushSyncer.sendTestPush(
            title: "cmux test",
            body: "Push notification from cmux"
        )
    }

    func handleDeviceToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        tokenStore.save(token)
        #if DEBUG
        log.debug("APNs device token (hex): \(token, privacy: .private)")
        #endif
        PushNotificationConfigurator.shared.updateDeviceToken(token)
        Task {
            await syncTokenIfPossible()
        }
    }

    func handleRegistrationFailure(_ error: Error) {
        log.error("Failed to register for remote notifications: \(error.localizedDescription, privacy: .public)")
    }

    func handleNotificationUserInfo(_ userInfo: [AnyHashable: Any]) {
        routeStore.store(userInfo: userInfo)
    }

    // MARK: - Terminal local notifications

    private var recentSeqs: [String: [UInt64]] = [:]
    private let recentSeqLimit = 64

    func handleTerminalNotifications(
        sessionID: String,
        seq: UInt64,
        payload: TerminalNotificationsPayload
    ) {
        if isDuplicate(sessionID: sessionID, seq: seq) { return }
        guard isAuthorized else { return }

        let appForeground = UIApplication.shared.applicationState == .active

        if payload.bell, !appForeground {
            scheduleLocal(
                title: "Terminal bell",
                body: sessionID,
                identifier: "bell-\(sessionID)-\(seq)",
                sound: .default
            )
        }
        if let cf = payload.commandFinished, !appForeground {
            let body: String
            if let exit = cf.exitCode {
                body = "Exit \(exit)"
            } else {
                body = "Completed"
            }
            scheduleLocal(
                title: "\(sessionID) finished",
                body: body,
                identifier: "cmd-\(sessionID)-\(seq)",
                sound: .default
            )
        }
        if let n = payload.notification {
            let title = n.title?.nilIfEmpty ?? "Notification"
            let body = n.body ?? ""
            scheduleLocal(
                title: title,
                body: body,
                identifier: "notif-\(sessionID)-\(seq)",
                sound: .default
            )
        }
    }

    private func isDuplicate(sessionID: String, seq: UInt64) -> Bool {
        var seqs = recentSeqs[sessionID] ?? []
        if seqs.contains(seq) { return true }
        seqs.append(seq)
        if seqs.count > recentSeqLimit {
            seqs.removeFirst(seqs.count - recentSeqLimit)
        }
        recentSeqs[sessionID] = seqs
        return false
    }

    private func scheduleLocal(
        title: String,
        body: String,
        identifier: String,
        sound: UNNotificationSound?
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let sound { content.sound = sound }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("Local notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    var pendingRouteForTesting: NotificationRoute? {
        routeStore.pendingRoute
    }

    func syncTokenIfPossible() async {
        await refreshAuthorizationStatus()
        guard isAuthorized else {
            await removeTokenIfNeeded()
            return
        }

        guard pushSyncer.isAuthenticated else {
            return
        }

        guard let token = tokenStore.load() else {
            return
        }

        guard let bundleId = deviceInfo.bundleIdentifier else {
            log.error("Missing bundle identifier, cannot register push token.")
            return
        }

        let environment: MobilePushEnvironment = Environment.current == .development
            ? .development
            : .production
        let deviceId = deviceInfo.vendorIdentifier

        do {
            try await pushSyncer.upsertPushToken(
                token: token,
                environment: environment,
                platform: "ios",
                bundleId: bundleId,
                deviceId: deviceId
            )
        } catch {
            log.error("Failed to sync push token: \(error.localizedDescription, privacy: .public)")
        }
    }

    func unregisterFromServer() async {
        guard let token = tokenStore.load() else {
            return
        }

        guard pushSyncer.isAuthenticated else {
            tokenStore.clear()
            return
        }

        do {
            try await pushSyncer.removePushToken(token: token)
            tokenStore.clear()
        } catch {
            log.error("Failed to remove push token: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeTokenIfNeeded() async {
        guard tokenStore.load() != nil else {
            return
        }
        await unregisterFromServer()
    }

    private func registerForRemoteNotifications() {
        if system.isRegisteredForRemoteNotifications {
            isRegisteredForRemoteNotifications = true
            return
        }
        system.registerForRemoteNotifications()
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .list, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            handleNotificationUserInfo(response.notification.request.content.userInfo)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum NotificationRequestTrigger: String {
    case createConversation
    case sendMessage
    case settings
    case launch
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
