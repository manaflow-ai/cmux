import CmuxiOSPlatform
import CmuxiOSPush
import UserNotifications

/// The app's notification-center delegate: banners show while the app is in
/// front; a tap on a routed push (C7's `cmux.route` keys) goes to the
/// router; feed banner actions go to the feed responder.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let responder: FeedNotificationResponder
    private let router: ShellRouter
    private let decoder: NotificationRouteDecoder

    @MainActor
    init(responder: FeedNotificationResponder, router: ShellRouter) {
        self.responder = responder
        self.router = router
        decoder = NotificationRouteDecoder(parser: router.parser)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let route = decoder.route(from: response.notification.request.content.userInfo) {
            let router = self.router
            await MainActor.run { _ = router.openNotification(route) }
            return
        }
        let decision = FeedNotificationResponder.decision(for: response)
        await responder.handle(decision)
    }
}
