import CmuxiOSFeatureKit
import Foundation

/// Reads a route from a notification payload (the hook C7 fills
/// server-side): `cmux.route` with a link in the router grammar, or
/// `cmux.host` plus `cmux.workspace` (and optional `cmux.surface`).
public struct NotificationRouteDecoder: Sendable {
    public static let routeKey = "cmux.route"
    public static let hostKey = "cmux.host"
    public static let workspaceKey = "cmux.workspace"
    public static let surfaceKey = "cmux.surface"
    private let parser: ShellRouteParser

    public init(parser: ShellRouteParser) { self.parser = parser }

    /// Nil when the payload carries no route keys (not a routed push) or
    /// the route is malformed.
    public func route(from userInfo: [AnyHashable: Any]) -> ShellRoute? {
        if let link = userInfo[Self.routeKey] as? String {
            return URL(string: link).flatMap(parser.route(for:))
        }
        guard let host = userInfo[Self.hostKey] as? String,
              let workspace = userInfo[Self.workspaceKey] as? String,
              ShellRouteParser.isValidID(host), ShellRouteParser.isValidID(workspace) else { return nil }
        let surface = userInfo[Self.surfaceKey] as? String
        if let surface, !ShellRouteParser.isValidID(surface) { return nil }
        return .workspace(host: HostID(host), workspace: workspace, surface: surface)
    }
}
