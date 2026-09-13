import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct MobileHostIdentityConcurrencyTests {
    @Test func dismissalWarmupGateDoesNotResolveIdentityOnTheSynchronousPath() throws {
        let prewarm = PhonePushIdentityPrewarm(
            identityProvider: NeverReadyPhonePushIdentityProvider()
        )
        #expect(prewarm.deviceIDIfReady() == nil)
        prewarm.appendDismissals(ids: ["dismissal"], badgeCount: 1)
        let pending = try #require(prewarm.takePendingDismissals())
        #expect(pending.ids == ["dismissal"])
        #expect(pending.badgeCount == 1)
    }

    @Test func pendingDismissalsStayBoundedWhileIdentityWarms() throws {
        let buffer = PhonePushIdentityPrewarm()
        buffer.appendDismissals(
            ids: (0..<300).map(String.init),
            badgeCount: 7
        )

        let pending = try #require(buffer.takePendingDismissals())
        #expect(pending.ids.count == 256)
        #expect(pending.ids.first == "44")
        #expect(pending.ids.last == "299")
        #expect(pending.badgeCount == 7)
        #expect(buffer.takePendingDismissals() == nil)
    }

    @Test func sessionResetDropsBufferedDismissalsBeforeTheyCanFlush() throws {
        let buffer = PhonePushIdentityPrewarm()
        buffer.appendDismissals(ids: ["account-a"], badgeCount: 2)
        buffer.reset()
        #expect(buffer.takePendingDismissals() == nil)
    }

    @Test func prewarmPublishesOneProcessStableSnapshotForConcurrentCallers() async {
        await MobileHostIdentity.prewarm()
        let expected = MobileHostIdentity.deviceIDIfReady()
        #expect(expected != nil)

        let values = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<16 {
                group.addTask {
                    MobileHostIdentity.deviceID()
                }
            }
            var values: [String] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        #expect(values.count == 16)
        #expect(values.allSatisfy { $0 == expected })
        #expect(MobileHostIdentity.deviceIDIfReady() == expected)
    }
}

private struct NeverReadyPhonePushIdentityProvider: PhonePushIdentityProvider {
    func deviceIDIfReady() -> String? { nil }
    func prewarm() async {}
}
