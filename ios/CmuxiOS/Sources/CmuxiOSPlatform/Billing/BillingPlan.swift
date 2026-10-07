import Foundation

/// One purchasable plan as the store presents it.
public struct BillingPlan: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// The store's localized price ("$9.99 / month").
    public let displayPrice: String
    public let summary: String

    public init(id: String, name: String, displayPrice: String, summary: String) {
        self.id = id
        self.name = name
        self.displayPrice = displayPrice
        self.summary = summary
    }
}
