import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The reader's bounds are flow control: a consumer that falls behind slows the transport down
/// instead of ending the stream.
@Suite struct RemoteTmuxProcessOutputReaderTests {
    /// A transport that delivers faster than the parser releases must slow down, not end the
    /// stream: ending it is what turned a burst after a network drop into a full reconnect.
    @Test(.timeLimit(.minutes(1))) func readerStopsReadingWhileTheConsumerHoldsAFullBuffer() async throws {
        let pipe = Pipe()
        let bound = 1000
        let reader = RemoteTmuxProcessOutputReader(
            label: "remote-tmux-process-output-reader-held-test",
            maxPendingChunks: 64,
            maxPendingBytes: bound
        )
        let held = HeldOutputChunks()
        reader.attach(to: pipe.fileHandleForReading)
        let capture = Task.detached {
            var data = Data()
            for await chunk in reader.stream {
                data.append(chunk)
                if held.holdOrRelease(chunk) { reader.release(chunk) }
            }
            return data
        }
        defer {
            reader.close()
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }

        let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        // Stopping is a suspended read source, which announces nothing, so this waits on the
        // reader's pause counter, and on the consumer task having taken the chunks the reader
        // published before it paused. The consumer holds every chunk, so the reader cannot
        // resume and the counter cannot pass 1 while this waits.
        let deadline = ContinuousClock.now + .seconds(30)
        while reader.pauseCount == 0 || held.byteCount < bound, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(reader.pauseCount == 1)
        #expect(held.byteCount == bound)
        for chunk in held.stopHolding() { reader.release(chunk) }

        #expect(await capture.value == payload)
    }

    @Test(.timeLimit(.minutes(1))) func processExitDrainsEveryByteToASlowConsumer() async throws {
        let pipe = Pipe()
        let reader = RemoteTmuxProcessOutputReader(
            label: "remote-tmux-process-output-reader-slow-drain-test",
            maxPendingChunks: 2,
            maxPendingBytes: 1000
        )
        reader.attach(to: pipe.fileHandleForReading)
        let capture = Task.detached {
            var data = Data()
            for await chunk in reader.stream {
                data.append(chunk)
                try? await Task.sleep(for: .milliseconds(2))
                reader.release(chunk)
            }
            return data
        }
        defer {
            reader.close()
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }

        let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        reader.processDidExit()

        #expect(await capture.value == payload)
    }
}

/// Chunks a test consumer keeps unreleased until the test lets go of them.
private final class HeldOutputChunks: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var holding = true

    var byteCount: Int {
        lock.withLock { chunks.reduce(0) { $0 + $1.count } }
    }

    /// Keeps the chunk while holding; returns true when the caller should release it now.
    func holdOrRelease(_ chunk: Data) -> Bool {
        lock.withLock {
            guard holding else { return true }
            chunks.append(chunk)
            return false
        }
    }

    /// Stops holding and hands back what was held, for the caller to release.
    func stopHolding() -> [Data] {
        lock.withLock {
            holding = false
            defer { chunks = [] }
            return chunks
        }
    }
}
