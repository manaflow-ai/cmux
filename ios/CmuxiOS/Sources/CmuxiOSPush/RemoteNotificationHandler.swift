public import CmuxFeedPushCore
import Foundation
import UserNotifications

/// Background pushes from the feed owner (c7-notify.md section 3): removes
/// banners for items answered or read elsewhere and sets the badge.
@MainActor
public final class RemoteNotificationHandler {
    public init() {}

    /// True when `userInfo` was a dismiss push (new data for the fetch result).
    public func handle(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard let dismiss = RemoteDismiss(userInfo: userInfo) else { return false }
        await apply(dismiss)
        return true
    }

    public func apply(_ dismiss: RemoteDismiss) async {
        let center = UNUserNotificationCenter.current()
        if !dismiss.items.isEmpty { center.removeDeliveredNotifications(withIdentifiers: dismiss.items) }
        if let badge = dismiss.badge { try? await center.setBadgeCount(badge) }
    }
}
