import Foundation

/// Lets native callbacks and main-actor tasks run while a hosted-view test waits.
@MainActor
struct AppKitTestEventPump {
    func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            await drain()
        }
        return true
    }
}
