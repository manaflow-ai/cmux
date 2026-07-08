import Foundation
import IOKit.pwr_mgt
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct PreventSleepDecisionTests {
    @Test(arguments: [
        (false, false, 0, 0, false),
        (false, false, 0, 1, false),
        (false, false, 1, 0, false),
        (false, false, 1, 1, false),
        (false, true, 0, 0, false),
        (false, true, 0, 1, true),
        (false, true, 1, 0, false),
        (false, true, 1, 1, true),
        (true, false, 0, 0, false),
        (true, false, 0, 1, false),
        (true, false, 1, 0, true),
        (true, false, 1, 1, true),
        (true, true, 0, 0, false),
        (true, true, 0, 1, true),
        (true, true, 1, 0, true),
        (true, true, 1, 1, true),
    ])
    func decisionTruthTable(
        agentsSettingEnabled: Bool,
        mobileSettingEnabled: Bool,
        runningAgentCount: Int,
        mobileConnectionCount: Int,
        expected: Bool
    ) {
        #expect(preventSleepDesired(
            agentsSettingEnabled: agentsSettingEnabled,
            mobileSettingEnabled: mobileSettingEnabled,
            runningAgentCount: runningAgentCount,
            mobileConnectionCount: mobileConnectionCount
        ) == expected)
    }

    @Test @MainActor
    func powerAssertionHolderAcquireReleaseAreIdempotent() {
        var createCount = 0
        var releaseCount = 0
        var releasedIDs: [IOPMAssertionID] = []
        let holder = PowerAssertionHolder(
            type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            reason: "cmux test assertion",
            createAssertion: { _, _ in
                createCount += 1
                return (kIOReturnSuccess, IOPMAssertionID(42))
            },
            releaseAssertion: { id in
                releaseCount += 1
                releasedIDs.append(id)
                return kIOReturnSuccess
            }
        )

        #expect(holder.isHeld == false)
        holder.acquire()
        holder.acquire()
        #expect(holder.isHeld == true)
        #expect(createCount == 1)

        holder.release()
        holder.release()
        #expect(holder.isHeld == false)
        #expect(releaseCount == 1)
        #expect(releasedIDs == [IOPMAssertionID(42)])
    }
}
