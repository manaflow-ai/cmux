import Foundation

/// One 429 answer from the Stack API, reduced to fields that are safe to
/// report: no tokens, no query strings, no ids.
public struct StackAuthRateLimitObservation: Sendable, Equatable {
    /// The shape of the 429 body. The Stack API answers JSON; an edge
    /// throttle in front of it answers an HTML page.
    public enum BodyKind: String, Sendable {
        case json, html, other
    }

    /// The request path without query, with id-like segments replaced by
    /// `ID`, for example `/api/v1/users/me` or `/api/v1/teams/ID`.
    public let endpoint: String
    public let bodyKind: BodyKind
    /// The server's `Retry-After`, in seconds, when it sent one.
    public let retryAfterSeconds: TimeInterval?
    /// Set only for the refresh-token exchange: the cooldown the SDK chose
    /// before the next exchange, in seconds.
    public let refreshBackoffSeconds: TimeInterval?
    /// Set only for the refresh-token exchange: consecutive rate-limited
    /// exchanges, starting at 1.
    public let refreshAttempt: Int?

    /// Whether this 429 answered the refresh-token exchange.
    public var isTokenRefresh: Bool { refreshAttempt != nil }

    public init(
        endpoint: String,
        bodyKind: BodyKind,
        retryAfterSeconds: TimeInterval?,
        refreshBackoffSeconds: TimeInterval? = nil,
        refreshAttempt: Int? = nil
    ) {
        self.endpoint = endpoint
        self.bodyKind = bodyKind
        self.retryAfterSeconds = retryAfterSeconds
        self.refreshBackoffSeconds = refreshBackoffSeconds
        self.refreshAttempt = refreshAttempt
    }
}

/// Receives the SDK's rate-limit signals. Calls arrive on arbitrary tasks and
/// must return quickly.
public protocol StackAuthRateLimitObserver: Sendable {
    /// A Stack call was answered 429. Request 429s arrive only when no
    /// caller reports them (see ``StackAuthRateLimitReporting/callerReports``);
    /// refresh-exchange 429s always arrive.
    func stackAuthDidRateLimit(_ observation: StackAuthRateLimitObservation)
    /// A refresh-token exchange succeeded after at least one 429.
    func stackAuthTokenRefreshDidRecover()
    /// A request outside a caller-reported scope succeeded.
    func stackAuthRequestDidSucceed()
}

/// Process-wide routing of SDK rate-limit signals to one observer.
public enum StackAuthRateLimitReporting {
    /// Set by an app flow that reports the 429s of its own calls with its
    /// own backoff, so the SDK does not report them a second time. Tasks
    /// created inside the scope inherit it, so keep the scope to the calls
    /// the flow reports; refresh-exchange 429s are reported regardless.
    @TaskLocal public static var callerReports = false

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: (any StackAuthRateLimitObserver)?

    /// Installs the observer; `nil` removes it.
    public static func setObserver(_ observer: (any StackAuthRateLimitObserver)?) {
        lock.lock()
        installed = observer
        lock.unlock()
    }

    static var observer: (any StackAuthRateLimitObserver)? {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    /// Classifies a 429 body by its content type, then by its first byte.
    static func bodyKind(contentType: String?, data: Data) -> StackAuthRateLimitObservation.BodyKind {
        let type = contentType?.lowercased() ?? ""
        if type.contains("json") { return .json }
        if type.contains("html") { return .html }
        let first = data.prefix(64).first { !Character(UnicodeScalar($0)).isWhitespace }
        switch first {
        case UInt8(ascii: "<"): return .html
        case UInt8(ascii: "{"), UInt8(ascii: "["): return .json
        default: return .other
        }
    }

    /// The URL path with any id, token, or address segment replaced by `ID`.
    static func endpoint(of url: URL?) -> String {
        guard let path = url?.path, !path.isEmpty else { return "/" }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            let text = String(segment)
            return isIdentifierLike(text) ? "ID" : text
        }
        let joined = segments.joined(separator: "/")
        return String(joined.prefix(200))
    }

    /// Keeps only segments shaped like route words (`users`, `sign-in`,
    /// `v1`); anything else, including ids, tokens and addresses, is an id.
    private static func isIdentifierLike(_ segment: String) -> Bool {
        guard let first = segment.first else { return false }
        let isVersion = first == "v" && (2...3).contains(segment.count)
            && segment.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
        if isVersion { return false }
        let isRouteWord = segment.count <= 24
            && first.isASCII && first.isLowercase
            && segment.allSatisfy { ($0.isASCII && $0.isLowercase) || $0 == "-" || $0 == "_" }
        return !isRouteWord
    }
}

extension StackAuthError {
    /// `details` key holding the reported endpoint of a 429.
    public static let endpointKey = "endpoint"
    /// `details` key holding the ``StackAuthRateLimitObservation/BodyKind`` raw value of a 429.
    public static let bodyKindKey = "body_kind"
}
