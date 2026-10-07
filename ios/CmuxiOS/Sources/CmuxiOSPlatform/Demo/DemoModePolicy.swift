import Foundation

/// App Review demo content (c16-platform.md section 7): on when the
/// account's remote config says so (B1 sets it for the review account) or,
/// in DEBUG, when `CMUX_IOS_DEMO=1`. While on, every seam serves its mock's
/// canned fixtures and nothing is persisted.
public struct DemoModePolicy: Sendable {
    public static let environmentKey = "CMUX_IOS_DEMO"
    private let environment: [String: String]
    private let isDebug: Bool

    public init(environment: [String: String], isDebug: Bool) {
        self.environment = environment
        self.isDebug = isDebug
    }

    public func isActive(remote: RemoteConfig) -> Bool {
        if isDebug, environment[Self.environmentKey] == "1" { return true }
        return remote.demoContent
    }
}
