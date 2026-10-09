import CmuxiOSFeatureKit
import CmuxiOSPlatform
import Foundation
import Testing

@Suite("Keep awake and billing")
struct KeepAwakeBillingTests {
    @Test func keepAwakeCommitsOnSupportedMacAndRefusesOtherwise() async throws {
        let control = MockKeepAwakeControl()
        let macs = MockFixtures.hosts().prefix(2).map(\.id)
        let committed = try await control.set(macs[0], enabled: true, key: IntentKey())
        guard case .committed = committed else { Issue.record("expected commit"); return }
        let refused = try await control.set(macs[1], enabled: true, key: IntentKey())
        guard case .refused = refused else { Issue.record("expected refusal"); return }
        let state = await control.hub.current.value
        #expect(state[macs[0]]?.isEnabled == true)
        #expect(state[macs[1]]?.isEnabled == nil)
    }

    @Test func keepAwakeOfflineThrowsAndNothingQueues() async throws {
        let control = MockKeepAwakeControl()
        await control.hub.setConnection(.offline(reason: nil))
        let mac = MockFixtures.hosts()[0].id
        await #expect(throws: FeatureSourceError.self) {
            _ = try await control.set(mac, enabled: true, key: IntentKey())
        }
        await control.hub.setConnection(.live(path: "mock"))
        #expect(await control.hub.current.value[mac]?.isEnabled == false)
    }

    @Test func billingPurchaseSwitchesPlanAndUnknownPlanRefuses() async throws {
        let store = MockBillingStore()
        _ = try await store.purchase("pro.yearly", key: IntentKey())
        #expect(await store.hub.current.value.currentPlanID == "pro.yearly")
        let refused = try await store.purchase("nope", key: IntentKey())
        guard case .refused = refused else { Issue.record("expected refusal"); return }
        _ = try await store.restore(key: IntentKey())
        #expect(await store.hub.current.value.currentPlanID == "pro.yearly")
    }

    @Test func billingProjectionDropsExpiredAndRevokedEntitlements() {
        let now = Date(timeIntervalSince1970: 2_000)
        let entitlements = [
            BillingEntitlement(productID: "old", transactionID: "1", purchasedAt: Date(timeIntervalSince1970: 1_000), expirationDate: now.addingTimeInterval(-1)),
            BillingEntitlement(productID: "revoked", transactionID: "2", purchasedAt: Date(timeIntervalSince1970: 1_500), revocationDate: now.addingTimeInterval(-1)),
            BillingEntitlement(productID: "pro.yearly", transactionID: "3", purchasedAt: Date(timeIntervalSince1970: 1_900), expirationDate: now.addingTimeInterval(60)),
        ]
        #expect(BillingStateProjection.currentPlanID(from: entitlements, at: now) == "pro.yearly")
    }

    @Test func billingProjectionUsesNewestPurchaseAndStableTieBreak() {
        let when = Date(timeIntervalSince1970: 2_000)
        let entitlements = [
            BillingEntitlement(productID: "pro.yearly", transactionID: "b", purchasedAt: when),
            BillingEntitlement(productID: "pro.monthly", transactionID: "a", purchasedAt: when),
        ]
        #expect(BillingStateProjection.currentPlanID(from: entitlements, at: when) == "pro.monthly")
    }

    @Test func storeKitConfigurationPrefersEnvironmentAndBoundsProductIDs() {
        let config = StoreKitBillingConfiguration.fromEnvironment(
            environment: ["CMUX_IOS_STOREKIT_PRODUCTS": "pro.monthly, invalid id,pro.monthly,pro.yearly"],
            bundle: Bundle(for: ConfigurationBundleMarker.self)
        )
        #expect(config.productIDs == ["pro.monthly", "pro.yearly"])
    }

    @Test func billingErrorsAreBoundedAndMappedWithoutLeakingRawText() {
        let mapped = BillingErrorMapper.map(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        #expect(mapped == .network)
        #expect(mapped.userMessage.count < 160)
        #expect(BillingErrorMapper.message(for: StoreKitBillingError.verificationFailed).contains("verified"))
    }

    @Test func storeKitUsesMockOnlyWhenExplicitFallbackIsEnabled() async throws {
        let fallback = MockBillingStore()
        let store = StoreKitBillingStore(
            configuration: StoreKitBillingConfiguration(productIDs: [], fallbackToMockWhenUnavailable: true),
            fallback: fallback
        )
        let stream = await store.updates()
        var iterator = stream.makeAsyncIterator()
        let snapshot = await iterator.next()
        #expect(snapshot?.connection == .live(path: "mock"))
        #expect(snapshot?.value.plans.map(\.id) == ["pro.monthly", "pro.yearly"])
        let receipt = try await store.purchase("pro.monthly", key: IntentKey(rawValue: "fallback"))
        guard case .committed = receipt else { Issue.record("expected mock fallback commit"); return }
    }
}

private final class ConfigurationBundleMarker {}
