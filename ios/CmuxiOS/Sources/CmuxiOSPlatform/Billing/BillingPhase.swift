import Foundation

/// What the store is doing right now.
public enum BillingPhase: Hashable, Sendable {
    case idle
    case purchasing(planID: String)
    case restoring
}
