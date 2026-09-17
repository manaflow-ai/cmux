import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct CaffeineControllerTests {
    @Test
    func activityIsAcquiredAndReleasedExactlyOncePerTransition() {
        let token = NSObject()
        var beginCount = 0
        var endedTokens: [ObjectIdentifier] = []
        var stateChanges: [Bool] = []
        let controller = CaffeineController(
            beginActivity: {
                beginCount += 1
                return token
            },
            endActivity: { activity in
                endedTokens.append(ObjectIdentifier(activity))
            }
        )
        controller.onStateChange = { stateChanges.append($0) }

        controller.setEnabled(true)
        controller.setEnabled(true)

        #expect(controller.isEnabled)
        #expect(beginCount == 1)
        #expect(endedTokens.isEmpty)
        #expect(stateChanges == [true])

        controller.setEnabled(false)
        controller.setEnabled(false)

        #expect(!controller.isEnabled)
        #expect(endedTokens == [ObjectIdentifier(token)])
        #expect(stateChanges == [true, false])
    }

    @Test
    func toggleUsesTheSameStateTransitionPath() {
        let token = NSObject()
        var releaseCount = 0
        let controller = CaffeineController(
            beginActivity: { token },
            endActivity: { _ in releaseCount += 1 }
        )

        controller.toggle()
        #expect(controller.isEnabled)

        controller.toggle()
        #expect(!controller.isEnabled)
        #expect(releaseCount == 1)
    }
}
