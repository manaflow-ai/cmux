import CmuxiOSPush
import UserNotifications

/// The app's notification-center delegate: banners show while the app is in
/// front; banner actions go to the feed responder.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let responder: FeedNotificationResponder
    /// Cloud attention notifications open the relay-backed chat screen. The
    /// callback is main-actor isolated because it owns UIKit navigation.
    var onCloudAttention: (@MainActor (CloudChatAttention) -> Void)?

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
        if let attention = CloudChatAttention(userInfo: response.notification.request.content.userInfo) {
            await MainActor.run { [weak self] in self?.onCloudAttention?(attention) }
            return
        }
        let decision = FeedNotificationResponder.decision(for: response)
        await responder.handle(decision)
    }
}
