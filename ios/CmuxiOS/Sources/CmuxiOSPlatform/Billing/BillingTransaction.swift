public import CmuxiOSFeatureKit
import Foundation

/// The small, framework-independent part of a verified StoreKit transaction
/// that the cloud billing owner needs.  StoreKit's `Transaction` is not part
/// of the app protocol so this value can also be used by a server-backed
/// implementation and by package tests.
public struct BillingTransaction: Codable, Hashable, Sendable {
    public let productID: String
    public let transactionID: String
    public let originalTransactionID: String
    public let purchaseDate: Date
    public let signedDate: Date
    public let expirationDate: Date?
    public let revocationDate: Date?
    /// The JWS is handed to the owner for server-side verification.  It is
    /// never logged or included in user-facing diagnostics.
    public let jwsRepresentation: String

    public init(
        productID: String,
        transactionID: String,
        originalTransactionID: String,
        purchaseDate: Date,
        signedDate: Date,
        expirationDate: Date? = nil,
        revocationDate: Date? = nil,
        jwsRepresentation: String
    ) {
        self.productID = productID
        self.transactionID = transactionID
        self.originalTransactionID = originalTransactionID
        self.purchaseDate = purchaseDate
        self.signedDate = signedDate
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.jwsRepresentation = jwsRepresentation
    }
}

/// A verified entitlement used to project the StoreKit state into the small
/// `BillingState` consumed by the plans screen.
public struct BillingEntitlement: Hashable, Sendable {
    public let productID: String
    public let transactionID: String
    public let purchasedAt: Date
    public let expirationDate: Date?
    public let revocationDate: Date?

    public init(
        productID: String,
        transactionID: String,
        purchasedAt: Date,
        expirationDate: Date? = nil,
        revocationDate: Date? = nil
    ) {
        self.productID = productID
        self.transactionID = transactionID
        self.purchasedAt = purchasedAt
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
    }

    public func isActive(at date: Date) -> Bool {
        guard revocationDate == nil else { return false }
        guard let expirationDate else { return true }
        return expirationDate > date
    }
}

/// The result of handing a verified receipt to the cloud billing owner.
/// `currentPlanID` is authoritative when present; the local entitlement is
/// only used while an owner has not yet returned a plan projection.
public struct BillingOwnerReceipt: Hashable, Sendable {
    public let revision: UInt64
    public let currentPlanID: String?

    public init(revision: UInt64, currentPlanID: String? = nil) {
        self.revision = revision
        self.currentPlanID = currentPlanID
    }
}

/// C12's owner adapter.  The adapter receives only a verified, framework-free
/// transaction and an idempotency key; it must verify the JWS and apply the
/// entitlement exactly once before returning a receipt.
public protocol BillingTransactionSubmitting: Sendable {
    func submit(_ transaction: BillingTransaction, key: IntentKey) async throws -> BillingOwnerReceipt
}

/// A pure projection shared by StoreKit and tests.  If several subscriptions
/// are active, the newest purchase wins and the product id is the stable tie
/// breaker.  Revoked or expired transactions never become the current plan.
public extension BillingState {
    public static func currentPlanID(
        from entitlements: some Sequence<BillingEntitlement>,
        at date: Date = Date()
    ) -> String? {
        entitlements
            .filter { $0.isActive(at: date) }
            .sorted {
                if $0.purchasedAt != $1.purchasedAt { return $0.purchasedAt > $1.purchasedAt }
                if $0.productID != $1.productID { return $0.productID < $1.productID }
                return $0.transactionID < $1.transactionID
            }
            .first?.productID
    }
}
