import Foundation

/// Holds clock registration without changing the requested absolute deadline.
actor RefreshTimerRegistrationGate {
    private var parked = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?

    func park() async {
        parked = true
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitUntilParked() async {
        if parked { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
