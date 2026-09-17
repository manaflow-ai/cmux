import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud tunnel provider start gate")
struct CloudTunnelProviderStartGateTests {
    @Test("coalesces duplicate starts and answers later replays successfully")
    func coalescesDuplicateStarts() {
        let gate = CloudTunnelProviderStartGate()
        var callbackResults: [String] = []

        let first = gate.request { error in callbackResults.append(error == nil ? "success" : "failure") }
        let second = gate.request { error in callbackResults.append(error == nil ? "success" : "failure") }

        #expect(first == .begin(generation: 1))
        #expect(second == .coalesced(generation: 1, waiterCount: 2))

        let finish = gate.finish(error: nil)
        #expect(finish?.generation == 1)
        #expect(finish?.succeeded == true)
        #expect(finish?.callbackCount == 2)
        finish?.completions.forEach { $0(nil) }
        #expect(callbackResults == ["success", "success"])

        let replayCompletion: CloudTunnelProviderStartGate.Completion = { error in
            callbackResults.append(error == nil ? "success" : "failure")
        }
        let replay = gate.request(completion: replayCompletion)
        #expect(replay == .alreadyStarted(generation: 1))
        replayCompletion(nil)
        #expect(callbackResults == ["success", "success", "success"])
        #expect(gate.finish(error: nil) == nil)
    }

    @Test("a failed start releases waiters and permits a new generation")
    func failedStartResets() {
        let gate = CloudTunnelProviderStartGate()
        var callbackCount = 0
        let first = gate.request { _ in callbackCount += 1 }
        _ = gate.request { _ in callbackCount += 1 }
        #expect(first == .begin(generation: 1))

        let failure = gate.finish(error: CloudTunnelProviderTestError.failed)
        #expect(failure?.succeeded == false)
        #expect(failure?.callbackCount == 2)
        failure?.completions.forEach { $0(CloudTunnelProviderTestError.failed) }
        #expect(callbackCount == 2)

        let retry = gate.request { _ in callbackCount += 1 }
        #expect(retry == .begin(generation: 2))
    }

    private enum CloudTunnelProviderTestError: Error {
        case failed
    }
}
