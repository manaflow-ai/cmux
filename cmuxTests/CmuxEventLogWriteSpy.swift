import Foundation

/// A synchronous FileHandle dependency; the lock protects observations shared with the utility queue.
final class CmuxEventLogWriteSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int] = []
    private var onMainThread = false
    // Retained so a closed handle's address cannot be reused by a later one.
    private var handles: [FileHandle] = []
    private let failedCall: Int?
    private let beforeWrite: (@Sendable () throws -> Void)?

    init(failedCall: Int? = nil, beforeWrite: (@Sendable () throws -> Void)? = nil) {
        self.failedCall = failedCall
        self.beforeWrite = beforeWrite
    }

    var writeSizes: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return sizes
    }

    /// Identity of the handle passed to each write, in call order.
    var handleIdentities: [ObjectIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        return handles.map(ObjectIdentifier.init)
    }

    var wroteOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onMainThread
    }

    func write(_ handle: FileHandle, data: Data) throws {
        lock.lock()
        sizes.append(data.count)
        handles.append(handle)
        onMainThread = onMainThread || Thread.isMainThread
        let shouldFail = sizes.count == failedCall
        lock.unlock()
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        try beforeWrite?()
        try handle.write(contentsOf: data)
    }
}
