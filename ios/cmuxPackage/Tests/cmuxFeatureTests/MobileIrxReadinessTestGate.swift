/// Keeps a permission check suspended even when its caller is cancelled.
actor MobileIrxReadinessTestGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async -> Bool {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !released { await withCheckedContinuation { waiter = $0 } }
        return true
    }

    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiters.append($0) } }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
