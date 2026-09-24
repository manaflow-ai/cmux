import Darwin
import Foundation

/// Collects the control commands emitted by a test's physical key delivery.
@MainActor
struct RemoteTmuxInputCommandCapture {
    enum CaptureError: Error, Equatable {
        case timedOut(expected: Int, received: Int)
        case endOfFile(expected: Int, received: Int)
        case invalidExpectedCount
    }

    private enum DeadlineError: Error { case elapsed }

    func capture(
        from handle: FileHandle,
        expectedCount: Int,
        timeout: Duration = .seconds(5),
        clock: some Clock<Duration> = ContinuousClock(),
        onCommand: (String) -> Void = { _ in },
        sendInput: () throws -> Void
    ) async throws -> [String] {
        guard expectedCount > 0 else { throw CaptureError.invalidExpectedCount }
        try Task.checkCancellation()
        // A fatal input precondition must escape before waiting for any output.
        try sendInput()
        let descriptor = dup(handle.fileDescriptor)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let (chunks, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        // FileHandle.bytes can remain suspended on an open, silent pipe. A read
        // source bridges this fd into a stream that a deadline can finish.
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler { @Sendable in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                continuation.yield(Data(buffer.prefix(count)))
            } else if count == 0 {
                continuation.finish()
            } else if errno != EINTR && errno != EAGAIN {
                continuation.finish(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
        }
        // The source owns this duplicate. Closing only after event delivery
        // stops prevents teardown from racing a read or a reused descriptor.
        source.setCancelHandler { @Sendable in close(descriptor) }
        source.activate()
        let deadline = Task {
            do {
                try await clock.sleep(for: timeout)
                continuation.finish(throwing: DeadlineError.elapsed)
            } catch { /* Cancellation ends the deadline when capture finishes. */ }
        }
        defer {
            deadline.cancel()
            continuation.finish()
            source.cancel()
        }
        var lineData = Data()
        var commands: [String] = []
        do {
            for try await chunk in chunks {
                try Task.checkCancellation()
                for byte in chunk {
                    guard byte == UInt8(ascii: "\n") else {
                        lineData.append(byte)
                        continue
                    }
                    let line = String(decoding: lineData, as: UTF8.self)
                    lineData.removeAll(keepingCapacity: true)
                    guard line.hasPrefix("send-keys -t %4 ") else { continue }
                    commands.append(line)
                    onCommand(line)
                    if commands.count == expectedCount { return commands }
                }
            }
        } catch DeadlineError.elapsed {
            throw CaptureError.timedOut(expected: expectedCount, received: commands.count)
        }
        try Task.checkCancellation()
        throw CaptureError.endOfFile(expected: expectedCount, received: commands.count)
    }
}
