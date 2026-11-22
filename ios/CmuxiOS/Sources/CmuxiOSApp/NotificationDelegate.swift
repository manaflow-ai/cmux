import CmuxiOSPush
import UserNotifications

/// The app's notification-center delegate: banners show while the app is in
/// front; banner actions go to the feed responder.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let responder: FeedNotificationResponder

    @MainActor
    init(responder: FeedNotificationResponder) {
        self.responder = responder
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let decision = FeedNotificationResponder.decision(for: response)
        await responder.handle(decision)
    }
}
