import CmuxiOSFeatureKit
import CmuxiOSPlatform
import Foundation
import Testing

@Suite("Keep awake and billing mocks")
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
}
