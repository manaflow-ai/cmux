import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct RemoteTmuxInputCommandCaptureTests {
    private let capture = RemoteTmuxInputCommandCapture()

    @Test func silentPipeHasDeadline() async throws {
        let pipe = Pipe()
        let clock = CloudCommandDeadlineClock()
        defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        let task = Task {
            try await capture.capture(from: pipe.fileHandleForReading, expectedCount: 1, clock: clock) {}
        }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(5))
        await #expect(throws: RemoteTmuxInputCommandCapture.CaptureError.timedOut(expected: 1, received: 0)) {
            try await task.value
        }
    }

    @Test func incompleteOutputHasDeadline() async throws {
        let pipe = Pipe()
        let clock = CloudCommandDeadlineClock()
        let (received, continuation) = AsyncStream<Void>.makeStream()
        defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        let task = Task {
            try await capture.capture(
                from: pipe.fileHandleForReading,
                expectedCount: 2,
                clock: clock,
                onCommand: { _ in continuation.yield(); continuation.finish() }
            ) {
                try pipe.fileHandleForWriting.write(contentsOf: Data("send-keys -t %4 End\n".utf8))
            }
        }
        for await _ in received { break }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(5))
        await #expect(throws: RemoteTmuxInputCommandCapture.CaptureError.timedOut(expected: 2, received: 1)) {
            try await task.value
        }
    }

    @Test func incompleteEndOfFileFails() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        await #expect(throws: RemoteTmuxInputCommandCapture.CaptureError.endOfFile(expected: 2, received: 1)) {
            try await capture.capture(from: pipe.fileHandleForReading, expectedCount: 2) {
                try pipe.fileHandleForWriting.write(contentsOf: Data("send-keys -t %4 End\n".utf8))
                try pipe.fileHandleForWriting.close()
            }
        }
    }

    @Test func filtersCommandsAndPreservesOrder() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        let commands = try await capture.capture(from: pipe.fileHandleForReading, expectedCount: 2) {
            try pipe.fileHandleForWriting.write(contentsOf: Data("refresh-client\nsend-keys -t %5 Left\nsend-keys -t %4 -H ".utf8))
            try pipe.fileHandleForWriting.write(contentsOf: Data("78\nsend-keys -t %4 End\n".utf8))
        }
        #expect(commands == ["send-keys -t %4 -H 78", "send-keys -t %4 End"])
    }

    @Test func failedSendDoesNotWaitForOutput() async throws {
        enum FailedSend: Error { case rejected }
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        await #expect(throws: FailedSend.rejected) {
            try await capture.capture(from: pipe.fileHandleForReading, expectedCount: 1) {
                throw FailedSend.rejected
            }
        }
    }

    @Test func cancelledCaptureStopsWithoutClosingWriter() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await capture.capture(from: pipe.fileHandleForReading, expectedCount: 1) {
                continuation.yield()
                continuation.finish()
            }
        }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
