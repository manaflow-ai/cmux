import Foundation

public enum FeedPriority: String, Hashable, Sendable, CaseIterable, Comparable {
    case low
    case normal
    case high
    case urgent

    private var rank: Int {
        switch self {
        case .low: 0
        case .normal: 1
        case .high: 2
        case .urgent: 3
        }
    }

    public static func < (lhs: FeedPriority, rhs: FeedPriority) -> Bool { lhs.rank < rhs.rank }
}
