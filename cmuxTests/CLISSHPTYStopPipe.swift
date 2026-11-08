import Darwin
import Foundation

/// Owns both cancellation endpoints for a synchronous test reader.
final class CLISSHPTYStopPipe: @unchecked Sendable {
    // The worker's final close and the caller's synchronous stop share one FD owner.
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private let readFD: Int32
    private var writeFD: Int32
    private var didFinish = false

    init(stopReadFD: Int32, stopWriteFD: Int32) {
        readFD = stopReadFD
        writeFD = stopWriteFD
        finished.enter()
    }

    func requestStop() {
        lock.lock()
        defer { lock.unlock() }
        closeWriter()
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return }
        didFinish = true
        closeWriter()
        Darwin.close(readFD)
        finished.leave()
    }

    func waitForFinish() -> Bool {
        finished.wait(timeout: .now() + 5) == .success
    }

    private func closeWriter() {
        guard writeFD >= 0 else { return }
        // EOF wakes poll without ever writing into a pipe whose reader has exited.
        Darwin.close(writeFD)
        writeFD = -1
    }
}
