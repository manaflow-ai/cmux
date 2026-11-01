import CmuxiOSPush
import UserNotifications

/// The app's notification-center delegate: banners show while the app is in
/// front; banner actions go to the feed responder.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let responder: FeedNotificationResponder
    /// A cold-start tap can arrive before RootViewController installs its
    /// router. Keep the validated attention until the app is ready.
    @MainActor private var pendingCloudAttentions: [CloudChatAttention] = []
    /// Cloud attention notifications open the relay-backed chat screen. The
    /// callback is main-actor isolated because it owns UIKit navigation.
    @MainActor var onCloudAttention: (@MainActor (CloudChatAttention) -> Void)? {
        didSet {
            guard let onCloudAttention else { return }
            let pending = pendingCloudAttentions
            pendingCloudAttentions.removeAll()
            for attention in pending { onCloudAttention(attention) }
        }
    }

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
            await MainActor.run { [weak self] in self?.deliverCloudAttention(attention) }
            return
        }
        let decision = FeedNotificationResponder.decision(for: response)
        await responder.handle(decision)
    }

    @MainActor
    private func deliverCloudAttention(_ attention: CloudChatAttention) {
        guard let onCloudAttention else {
            pendingCloudAttentions.append(attention)
            return
        }
        onCloudAttention(attention)
    }
}
