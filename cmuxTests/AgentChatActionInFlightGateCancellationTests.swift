import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentChatActionInFlightGateCancellationTests {
    @Test func cancelledTerminationWaiterReturns() async {
        let completion = AgentChatSidecarProcessExitCompletion()
        let gate = AgentChatActionInFlightGate(sidecarStateFileStore: nil)
        gate.lock.withLock { state in
            state.terminationInProgress = true
            state.terminationCompletion = completion
        }

        let waiter = Task { await gate.waitForTermination() }
        waiter.cancel()

        await confirmation("cancelled termination waiter returns") { returned in
            Task {
                await waiter.value
                returned()
            }
        }

        gate.lock.withLock { state in
            state.terminationInProgress = false
            state.terminationCompletion = nil
        }
        await completion.finish(true)
        await waiter.value
    }
}
