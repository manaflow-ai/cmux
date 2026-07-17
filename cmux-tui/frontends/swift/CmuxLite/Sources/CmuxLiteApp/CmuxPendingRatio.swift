import CmuxLiteCore
import Foundation

/// One optimistic split ratio awaiting authoritative layout reconciliation.
struct CmuxPendingRatio {
    let requestID: UInt64
    let previousRatio: Double
    let ratio: Double
}
