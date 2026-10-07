/// Resolves a listener start exactly once.
actor StartGate {
    private var waiter: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    func finish(_ ready: Bool) {
        guard result == nil else { return }
        result = ready
        waiter?.resume(returning: ready)
        waiter = nil
    }
}
