public import CmuxiOSFeatureKit
import Foundation

/// One intent in the log: sent to the owner, waiting for its echo.
public struct PendingWorkspaceIntent: Hashable, Sendable {
    public var key: IntentKey
    public var intent: WorkspaceIntent
    /// The owner committed it at this seq; it leaves the log once the
    /// mirror reaches the seq (the echo is applied).
    public var committedAt: UInt64?

    public init(key: IntentKey, intent: WorkspaceIntent, committedAt: UInt64? = nil) {
        self.key = key
        self.intent = intent
        self.committedAt = committedAt
    }
}
