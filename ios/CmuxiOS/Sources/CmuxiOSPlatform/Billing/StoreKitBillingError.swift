import Foundation

/// Stable, bounded failure classes exposed by the StoreKit seam.  Raw
/// StoreKit/NSError descriptions are intentionally never shown or persisted.
public enum StoreKitBillingError: Error, Hashable, Sendable {
    case notConfigured
    case unavailable
    case productNotFound
    case cancelled
    case pending
    case verificationFailed
    case network
    case ownerUnavailable
    case ownerRefused
    case operationInProgress
    case unknown

    public var userMessage: String {
        switch self {
        case .notConfigured: "Plans are not configured for this build."
        case .unavailable: "Purchases are unavailable on this device."
        case .productNotFound: "That plan is no longer available."
        case .cancelled: "Purchase cancelled."
        case .pending: "Purchase is pending approval."
        case .verificationFailed: "The App Store purchase could not be verified."
        case .network: "Connect to the internet and try again."
        case .ownerUnavailable: "Billing service is unavailable. Try again later."
        case .ownerRefused: "The purchase could not be applied to this account."
        case .operationInProgress: "A billing operation is already in progress."
        case .unknown: "The purchase could not be completed."
        }
    }
}

public enum BillingErrorMapper {
    public static func map(_ error: Error) -> StoreKitBillingError {
        if let error = error as? StoreKitBillingError { return error }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .network
        }
        // StoreKit errors are deliberately mapped by their category name so
        // this pure layer remains buildable in package tests without linking
        // StoreKit.  No framework-provided text crosses the UI boundary.
        let category = String(reflecting: error).lowercased()
        if category.contains("usercancel") { return .cancelled }
        if category.contains("pending") { return .pending }
        if category.contains("network") || category.contains("notconnected") { return .network }
        if category.contains("verify") || category.contains("unverified") { return .verificationFailed }
        if category.contains("notentitled") || category.contains("notavailable") { return .unavailable }
        if category.contains("refused") { return .ownerRefused }
        return .unknown
    }

    public static func message(for error: Error) -> String { map(error).userMessage }
}
