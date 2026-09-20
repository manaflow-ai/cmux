import Foundation
@testable import StackAuth

actor RefreshExchangeGate {
    private var continuations: [CheckedContinuation<APIClient.RefreshOutcome, Never>] = []
    private var started: [CheckedContinuation<Void, Never>] = []
    private var calls = 0
    func exchange() async -> APIClient.RefreshOutcome {
        calls += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
            for waiter in started { waiter.resume() }
            started = []
        }
    }
    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started.append($0) }
    }
    func release(_ result: APIClient.RefreshOutcome) {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume(returning: result) }
    }
}
