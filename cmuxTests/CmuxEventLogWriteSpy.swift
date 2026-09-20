import Foundation

/// A synchronous FileHandle dependency; the lock protects observations shared with the utility queue.
final class CmuxEventLogWriteSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int] = []
    private var onMainThread = false
    private let failedCall: Int?

    init(failedCall: Int? = nil) {
        self.failedCall = failedCall
    }

    var writeSizes: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return sizes
    }

    var wroteOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onMainThread
    }

    func write(_ handle: FileHandle, data: Data) throws {
        lock.lock()
        sizes.append(data.count)
        onMainThread = onMainThread || Thread.isMainThread
        let shouldFail = sizes.count == failedCall
        lock.unlock()
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: data)
    }
}
