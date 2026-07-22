import CmuxAgentTruthKit

actor ControlledAgentProcessObservationCapturer {
    private var captureCount = 0
    private var cacheBypassRequests: [Bool] = []
    private var releases: [Int: CheckedContinuation<[ProcessObservation], Never>] = [:]
    private var callCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func capture(bypassingCache: Bool) async -> [ProcessObservation] {
        captureCount += 1
        cacheBypassRequests.append(bypassingCache)
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

    func bypassRequests() -> [Bool] {
        cacheBypassRequests
    }

    private func resumeSatisfiedCallCountWaiters() {
        let satisfied = callCountWaiters.filter { captureCount >= $0.count }
        callCountWaiters.removeAll { captureCount >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
