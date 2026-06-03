import CmuxInboxCore
import Foundation

// The NotificationRoute / NotificationRouteKind value types and their userInfo parser moved to
// the CmuxInboxCore package (iOS refactor wave 1). This store keeps the pending-route state; it
// is de-singletoned in wave 3.
@MainActor
@Observable
final class NotificationRouteStore {
    static let shared = NotificationRouteStore()

    private(set) var pendingRoute: NotificationRoute?

    func setPendingRoute(_ route: NotificationRoute?) {
        pendingRoute = route
    }

    func store(userInfo: [AnyHashable: Any]) {
        pendingRoute = NotificationRoute(userInfo: userInfo)
    }

    @discardableResult
    func consume() -> NotificationRoute? {
        let route = pendingRoute
        pendingRoute = nil
        return route
    }
}
