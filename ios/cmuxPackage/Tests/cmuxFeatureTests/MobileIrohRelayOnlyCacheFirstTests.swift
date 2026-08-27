import CmuxIrohTransport
import Foundation
import Testing
@testable import cmuxFeature

/// Relay-only activation policy source: a warm client (verified cached broker
/// binding + a restored policy with usable relays) activates on the verified
/// cached policy exactly like automatic mode, with the authenticated refresh
/// running immediately behind activation. A fresh install, or the account
/// whose previous cache-first activation failed, keeps the blocking refresh.
@MainActor
struct MobileIrohRelayOnlyCacheFirstTests {
    @Test
    func warmClientAttemptsCacheFirstActivation() {
        #expect(MobileIrohRuntimeComposition
            .shouldAttemptRelayOnlyCacheFirstActivation(
                hasVerifiedCachedBinding: true,
                accountID: "account-a",
                cacheFirstFailureAccountID: nil
            ))
    }

    @Test
    func freshEndpointKeepsTheBlockingPolicyRefresh() {
        #expect(!MobileIrohRuntimeComposition
            .shouldAttemptRelayOnlyCacheFirstActivation(
                hasVerifiedCachedBinding: false,
                accountID: "account-a",
                cacheFirstFailureAccountID: nil
            ))
    }

    @Test
    func failedCacheFirstActivationFallsBackToBlockingRefreshForThatAccount() {
        #expect(!MobileIrohRuntimeComposition
            .shouldAttemptRelayOnlyCacheFirstActivation(
                hasVerifiedCachedBinding: true,
                accountID: "account-a",
                cacheFirstFailureAccountID: "account-a"
            ))
        // Another account never inherits the failure backoff.
        #expect(MobileIrohRuntimeComposition
            .shouldAttemptRelayOnlyCacheFirstActivation(
                hasVerifiedCachedBinding: true,
                accountID: "account-b",
                cacheFirstFailureAccountID: "account-a"
            ))
    }
}
