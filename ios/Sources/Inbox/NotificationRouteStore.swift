import Foundation

enum NotificationRouteKind: String, Codable, Equatable, Sendable {
    case workspace
}

struct NotificationRoute: Codable, Equatable, Sendable {
    let kind: NotificationRouteKind
    let workspaceID: String
    let machineID: String?

    init(kind: NotificationRouteKind, workspaceID: String, machineID: String?) {
        self.kind = kind
        self.workspaceID = workspaceID
        self.machineID = machineID
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let routeObject = userInfo["route"] else {
            return nil
        }

        if let route = routeObject as? [String: Any] {
            guard let kindRaw = route["kind"] as? String,
                  let kind = NotificationRouteKind(rawValue: kindRaw),
                  let workspaceID = route["workspaceId"] as? String else {
                return nil
            }
            self.init(
                kind: kind,
                workspaceID: workspaceID,
                machineID: route["machineId"] as? String
            )
            return
        }

        if let routeString = routeObject as? String,
           let data = routeString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(NotificationRoutePayload.self, from: data),
           let kind = NotificationRouteKind(rawValue: decoded.kind) {
            self.init(kind: kind, workspaceID: decoded.workspaceId, machineID: decoded.machineId)
            return
        }

        return nil
    }
}

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

private struct NotificationRoutePayload: Decodable {
    let kind: String
    let workspaceId: String
    let machineId: String?
}
