import AppKit
import Foundation

/// Test-owned notification waiter for the real asynchronous syntax task.
final class FilePreviewTextStorageEditWaiter {
    private actor Signal {
        private var signaled = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            if signaled {
                signaled = false
                return
            }
            await withCheckedContinuation { continuation = $0 }
        }

        func signal() {
            if let continuation {
                self.continuation = nil
                continuation.resume()
            } else {
                signaled = true
            }
        }
    }

    private let signal = Signal()
    private let observer: NSObjectProtocol

    init(storage: NSTextStorage) {
        let signal = self.signal
        observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { _ in
            Task { await signal.signal() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(observer)
    }

    func wait() async {
        await signal.wait()
    }
}

/// Counts synchronous `NSTextStorage` edit notifications in a test.
final class EditNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
