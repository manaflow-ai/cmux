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
    public private(set) var isAccountReady = false
    public private(set) var pending: ShellRoute?
    /// Called for links this build does not understand (show "update cmux").
    public var onUnrecognized: (@MainActor (URL) -> Void)?

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
        guard ready != isAccountReady else { return }
        isAccountReady = ready
        if ready {
            deliverPending()
        } else {
            pending = nil
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
        guard let handler, isAccountReady || !route.requiresAccount else {
            pending = route
            log?.info("router", "deferred \(Self.name(route))")
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
        guard let route = pending, let handler, isAccountReady || !route.requiresAccount else { return }
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
        case .pairing: "pairing"
        }
    }
}
