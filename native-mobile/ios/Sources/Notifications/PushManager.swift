import Foundation
import Observation
import UIKit
import UserNotifications
import os

/// Push notifications: permission, the APNs device token, notification
/// categories, responses (answered through the Worker so they work from the
/// lock screen), and deep links into a terminal.
@MainActor
@Observable
final class PushManager: NSObject {
    static let shared = PushManager()
    static let log = Logger(subsystem: "dev.cmux.next.native", category: "push")

    /// Where a tapped notification or Live Activity wants to go.
    struct DeepLink: Equatable, Sendable {
        var hostID: String
        var surface: Int?
        var id = UUID()
    }

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var deviceToken: String?
    private(set) var lastError: String?
    /// Set by a notification tap; the signed-in root consumes it.
    var pendingDeepLink: DeepLink?
    /// Pre-prompt sheet (Claude-style) before the system permission alert.
    var showPrePrompt = false

    /// Live Activities for running agents (Codex has the same switch).
    var liveActivitiesEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.liveActivitiesKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.liveActivitiesKey)
            Task { await uploadRegistration() }
        }
    }

    static let liveActivitiesKey = "push.liveActivities"
    static let prePromptKey = "push.prePromptAnswered"

    private let tokenStore = SessionTokenStore()
    var api: PushAPI { PushAPI(token: tokenStore.value) }

    /// Called once at launch (app delegate).
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(PushCategory.base())
        Task {
            await refreshAuthorization()
            if authorization == .authorized || authorization == .provisional || authorization == .ephemeral {
                UIApplication.shared.registerForRemoteNotifications()
            }
            // Simulator checks: CMUX_NATIVE_PUSH_DEBUG=prompt shows the pre-prompt,
            // =authorize asks the system right away.
            switch ProcessInfo.processInfo.environment["CMUX_NATIVE_PUSH_DEBUG"] {
            case "prompt": showPrePrompt = true
            case "authorize": await answerPrePrompt(enable: true)
            default: break
            }
        }
        LiveActivityManager.shared.start()
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// After the first Mac connects: offer notifications once.
    func considerPrePrompt() {
        guard authorization == .notDetermined, !UserDefaults.standard.bool(forKey: Self.prePromptKey), !showPrePrompt else { return }
        showPrePrompt = true
    }

    func answerPrePrompt(enable: Bool) async {
        UserDefaults.standard.set(true, forKey: Self.prePromptKey)
        showPrePrompt = false
        guard enable else { return }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        } catch {
            Self.log.error("authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Token

    func didRegister(deviceToken data: Data) {
        deviceToken = data.hexString
        Self.log.info("apns token \(data.hexString.prefix(8), privacy: .public)… env \(Self.apsEnvironment, privacy: .public)")
        Task { await uploadRegistration() }
    }

    func didFailToRegister(_ error: any Error) {
        lastError = error.localizedDescription
        Self.log.error("apns registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Sends the device token, the Live Activity push-to-start token and the
    /// switches to the Worker. Runs on every token change and sign-in.
    func uploadRegistration() async {
        guard let deviceToken, tokenStore.value != nil else { return }
        do {
            try await api.register(
                deviceToken: deviceToken, environment: Self.apsEnvironment, bundleID: Bundle.main.bundleIdentifier,
                pushToStartToken: LiveActivityManager.shared.pushToStartToken,
                liveActivities: liveActivitiesEnabled, notifications: true)
        } catch {
            lastError = error.localizedDescription
            Self.log.error("register failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `aps-environment` from the embedded provisioning profile; simulator
    /// and unsigned builds use the sandbox.
    static let apsEnvironment: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<plist"), let end = text.range(of: "</plist>"),
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let env = entitlements["aps-environment"] as? String else { return "sandbox" }
        return env == "production" ? "production" : "sandbox"
    }()

    // MARK: Presence

    /// Tells the Mac whether cmux is on screen, so it holds back pushes.
    func reportPresence(visible: Bool, connection: HostConnection?) {
        guard let services = connection?.services else { return }
        let task = visible ? UIBackgroundTaskIdentifier.invalid : UIApplication.shared.beginBackgroundTask(withName: "presence")
        Task {
            _ = try? await services.call("presence.set", ["visible": .bool(visible)])
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    // MARK: Responses

    /// What a notification response carries, read off the delegate's thread.
    struct Response: Sendable {
        var payload: PushPayload
        var actionIdentifier: String
        var userText: String?

        init?(_ response: UNNotificationResponse) {
            guard let payload = PushPayload(userInfo: response.notification.request.content.userInfo) else { return nil }
            self.payload = payload
            actionIdentifier = response.actionIdentifier
            userText = (response as? UNTextInputNotificationResponse)?.userText
        }
    }

    func handle(response: Response) async {
        let payload = response.payload
        let id = response.actionIdentifier
        do {
            switch id {
            case UNNotificationDefaultActionIdentifier:
                pendingDeepLink = DeepLink(hostID: payload.hostID, surface: payload.surface)
                return
            case UNNotificationDismissActionIdentifier:
                return
            case PushCategory.replyAction:
                let text = response.userText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else { return }
                try await api.action(hostID: payload.hostID, eventID: payload.eventID, action: "reply", text: text)
            case PushCategory.allowAction:
                try await api.action(hostID: payload.hostID, eventID: payload.eventID, action: "allow")
            case PushCategory.denyAction:
                try await api.action(hostID: payload.hostID, eventID: payload.eventID, action: "deny")
            case let id where id.hasPrefix(PushCategory.optionPrefix):
                try await api.action(hostID: payload.hostID, eventID: payload.eventID, action: "option",
                                     key: String(id.dropFirst(PushCategory.optionPrefix.count)))
            default:
                return
            }
            Self.log.info("answered \(payload.eventID, privacy: .public) with \(id, privacy: .public)")
        } catch {
            Self.log.error("action failed: \(error.localizedDescription, privacy: .public)")
            await Self.notifyFailure(error, payload: payload)
        }
    }

    /// A local notification saying the answer did not reach the Mac.
    private static func notifyFailure(_ error: any Error, payload: PushPayload) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Couldn't send your answer")
        content.body = error.localizedDescription
        content.threadIdentifier = payload.surface.map { "host-\(payload.hostID)-surface-\($0)" } ?? "host-\(payload.hostID)"
        content.userInfo = ["cmux": ["host_id": payload.hostID, "event_id": payload.eventID, "kind": "notice", "surface": payload.surface as Any]]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// `cmux-next://terminal?host=<id>&surface=<n>` (Live Activity taps).
    func handle(url: URL) -> Bool {
        guard url.scheme == "cmux-next", url.host == "terminal",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value else { return false }
        pendingDeepLink = DeepLink(hostID: host, surface: items.first(where: { $0.name == "surface" })?.value.flatMap(Int.init))
        return true
    }
}

extension PushManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        // The Mac holds pushes while cmux is on screen; anything that still
        // arrives (another Mac, a race) shows as a banner.
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let parsed = Response(response) else { return }
        await handle(response: parsed)
    }
}

/// UIKit entry points SwiftUI does not offer: the APNs token callbacks and
/// setting the notification delegate before launch finishes.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushManager.shared.configure()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushManager.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushManager.shared.didFailToRegister(error)
    }
}
