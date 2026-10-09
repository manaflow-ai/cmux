public import CmuxiOSFeatureKit
public import Foundation

/// One entry of the intent log: sent (or being sent) and not yet retired.
public struct FeedPendingIntent: Hashable, Sendable, Identifiable {
    public var key: IntentKey
    public var intent: FeedIntent
    /// When the user acted (the overlay's answer and read times).
    public var at: Date
    /// Set when the owner committed it: the entry retires once the mirror
    /// reaches this revision.
    public var committedAt: UInt64?

    public init(key: IntentKey, intent: FeedIntent, at: Date, committedAt: UInt64? = nil) {
        self.key = key
        self.intent = intent
        self.at = at
        self.committedAt = committedAt
    }

    public var id: IntentKey { key }
}
