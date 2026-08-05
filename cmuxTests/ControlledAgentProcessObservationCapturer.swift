import CmuxAgentTruthKit

actor ControlledAgentProcessObservationCapturer {
    private var captureCount = 0
    private var releases: [Int: CheckedContinuation<[ProcessObservation], Never>] = [:]
    private var callCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func capture() async -> [ProcessObservation] {
        captureCount += 1
        let call = captureCount
        return await withCheckedContinuation { continuation in
            releases[call] = continuation
            resumeSatisfiedCallCountWaiters()
        }
    }

    func waitForCallCount(_ count: Int) async {
        guard captureCount < count else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((count, continuation))
        }
    }

    func release(call: Int, observations: [ProcessObservation] = []) {
        releases.removeValue(forKey: call)?.resume(returning: observations)
    }

    func callCount() -> Int {
        captureCount
    }

    private func resumeSatisfiedCallCountWaiters() {
        let satisfied = callCountWaiters.filter { captureCount >= $0.count }
        callCountWaiters.removeAll { captureCount >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
