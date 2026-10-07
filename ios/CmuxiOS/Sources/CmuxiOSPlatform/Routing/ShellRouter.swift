public import Foundation

/// The one owner of route delivery. Account-scoped routes wait while no
/// account is ready (signed out or restoring): one slot, newest wins,
/// delivered once when the shell becomes ready, dropped when an account
/// signs out. The shell installs one handler.
@MainActor
public final class ShellRouter {
    public typealias Handler = @MainActor (ShellRoute) -> Void

    public let parser: ShellRouteParser
    private let log: (any DiagnosticRecording)?
    private var handler: Handler?
    public private(set) var access: RouteAccess = .none
    public var isAccountReady: Bool { access == .account }
    public private(set) var pending: ShellRoute?
    /// Called for links this build does not understand (show "update cmux").
    public var onUnrecognized: (@MainActor (URL) -> Void)?
    /// Called when the guest shell parks a route that needs an account
    /// (show a sign-in prompt).
    public var onNeedsAccount: (@MainActor (ShellRoute) -> Void)?

    /// Which shell is on screen.
    public enum RouteAccess: Hashable, Sendable {
        case none
        /// The signed-out guest shell (deferred sign-in).
        case guest
        case account
    }

    public init(parser: ShellRouteParser, log: (any DiagnosticRecording)? = nil) {
        self.parser = parser
        self.log = log
    }

    public func install(_ handler: @escaping Handler) {
        self.handler = handler
        deliverPending()
    }

    /// True once the signed-in shell is on screen. A true-to-false change
    /// (sign-out) drops the parked route; false-to-true delivers it.
    public func setAccountReady(_ ready: Bool) {
        setAccess(ready ? .account : .none)
    }

    /// The shell on screen changed. Losing the account drops the parked
    /// route; reaching the guest or account shell delivers what it allows.
    public func setAccess(_ next: RouteAccess) {
        guard next != access else { return }
        let lostAccount = access == .account
        access = next
        if lostAccount {
            pending = nil
        } else {
            deliverPending()
        }
    }

    private func mayOpen(_ route: ShellRoute) -> Bool {
        switch access {
        case .account: true
        case .guest: route.allowsGuest || !route.requiresAccount
        case .none: !route.requiresAccount
        }
    }

    @discardableResult
    public func open(_ url: URL) -> ShellRouteOutcome {
        guard let route = parser.route(for: url) else {
            log?.warning("router", "unrecognized link scheme=\(url.scheme ?? "-")")
            onUnrecognized?(url)
            return .unrecognized
        }
        return open(route)
    }

    @discardableResult
    public func open(_ route: ShellRoute) -> ShellRouteOutcome {
        guard let handler, mayOpen(route) else {
            pending = route
            log?.info("router", "deferred \(Self.name(route))")
            if access == .guest { onNeedsAccount?(route) }
            return .deferred
        }
        log?.info("router", "open \(Self.name(route))")
        handler(route)
        return .handled
    }

    /// The C7 hook: routes a notification tap. Nil when the payload carries
    /// no route (the caller keeps its own handling).
    @discardableResult
    public func openNotification(_ route: ShellRoute?) -> ShellRouteOutcome? {
        route.map { open($0) }
    }

    private func deliverPending() {
        guard let route = pending, let handler, mayOpen(route) else { return }
        pending = nil
        log?.info("router", "deliver deferred \(Self.name(route))")
        handler(route)
    }

    /// A log-safe route name (no ids).
    static func name(_ route: ShellRoute) -> String {
        switch route {
        case .home: "home"
        case .feed: "feed"
        case .workspaces: "workspaces"
        case .workspace: "workspace"
        case .compose: "compose"
        case .hosts: "hosts"
        case .settings: "settings"
        case .diagnostics: "diagnostics"
        case .whatsNew: "whats-new"
        case .search: "search"
        case .pairing: "pairing"
        }
    }
}
