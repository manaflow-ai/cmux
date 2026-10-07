public import CmuxiOSFeatureKit

/// What the user learns after a banner action (c7-notify.md section 2).
public enum BannerActionOutcome: Hashable, Sendable {
    /// The owner committed it: remove the banner.
    case committed
    /// Someone answered first (`feed.closed`): say so, remove the banner.
    case answeredElsewhere
    /// Not sent or refused: say "Answer not sent"; the item stays open.
    case notSent(reason: String)

    public init(receipt: IntentReceipt) {
        switch receipt {
        case .committed: self = .committed
        case .refused(_, let reason): self = reason == "feed.closed" ? .answeredElsewhere : .notSent(reason: reason)
        }
    }

    public init(error: any Error) {
        self = .notSent(reason: String(describing: error))
    }

    /// Whether the delivered banner should go.
    public var removesBanner: Bool {
        switch self {
        case .committed, .answeredElsewhere: true
        case .notSent: false
        }
    }
}
