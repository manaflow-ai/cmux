import Foundation
import Testing
import CmuxCloudTunnelCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud tunnel provider start gate")
struct CloudTunnelProviderStartGateTests {
    @Test("coalesces duplicate starts and answers later replays successfully")
    func coalescesDuplicateStarts() async {
        let gate = CloudTunnelProviderStartGate()
        let recorder = CallbackRecorder()

        let first = await gate.request { error in recorder.append(error == nil ? "success" : "failure") }
        let second = await gate.request { error in recorder.append(error == nil ? "success" : "failure") }

        #expect(first == .begin(generation: 1))
        #expect(second == .coalesced(generation: 1, waiterCount: 2))

        let finish = await gate.finish(error: nil)
        #expect(finish?.generation == 1)
        #expect(finish?.succeeded == true)
        #expect(finish?.callbackCount == 2)
        finish?.completions.forEach { $0(nil) }
        #expect(recorder.values == ["success", "success"])

        let replayCompletion: CloudTunnelProviderStartGate.Completion = { error in
            recorder.append(error == nil ? "success" : "failure")
        }
        let replay = await gate.request(completion: replayCompletion)
        #expect(replay == .alreadyStarted(generation: 1))
        replayCompletion(nil)
        #expect(recorder.values == ["success", "success", "success"])
        #expect(await gate.finish(error: nil) == nil)
    }

    @Test("a failed start releases waiters and permits a new generation")
    func failedStartResets() async {
        let gate = CloudTunnelProviderStartGate()
        let recorder = CallbackRecorder()
        let first = await gate.request { _ in recorder.append("callback") }
        _ = await gate.request { _ in recorder.append("callback") }
        #expect(first == .begin(generation: 1))

        let failure = await gate.finish(error: CloudTunnelProviderError.invalidState)
        #expect(failure?.succeeded == false)
        #expect(failure?.callbackCount == 2)
        failure?.completions.forEach { $0(CloudTunnelProviderError.invalidState) }
        #expect(recorder.values.count == 2)

        let retry = await gate.request { _ in recorder.append("callback") }
        #expect(retry == .begin(generation: 2))
    }

    private final class CallbackRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ value: String) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

}
