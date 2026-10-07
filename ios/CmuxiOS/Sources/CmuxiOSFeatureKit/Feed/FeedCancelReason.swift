import Foundation

/// Why a request closed without an answer (feed.md 3.1 `cancel.reason`).
public enum FeedCancelReason: String, Hashable, Sendable {
    case poster
    case declined
    case answeredElsewhere = "answered_elsewhere"
    case superseded
    case posterGone = "poster_gone"
    case other
}
