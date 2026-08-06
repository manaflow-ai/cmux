import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

struct EventCursorPersistenceTests {
    @Test func quietStreamFlushesCursorBeforeServerHeartbeat() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-cursor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let socketPath = directory.appendingPathComponent("cmux.sock").path
        let cursorPath = directory.appendingPathComponent("events.seq").path
        let response = [
            #"{"type":"ack","protocol":"cmux-events","version":1}"#,
            #"{"type":"event","seq":41,"name":"test.event","category":"test"}"#,
        ].joined(separator: "\n")
        let responder = try UnixSocketResponder(path: socketPath, response: response)
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: BundledCLITestSupport.bundledCLIPath(for: Self.self)
        )
        process.arguments = [
            "events",
            "--cursor-file", cursorPath,
            "--no-ack",
            "--no-heartbeat",
        ]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: cursorPath),
              ContinuousClock.now < deadline
        {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let persistedCursor = try? String(contentsOfFile: cursorPath, encoding: .utf8)

        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        #expect(
            persistedCursor == "41\n",
            Comment(rawValue: "cursor was not flushed while the stream was quiet: \(output)")
        )
    }

    @Test func burstWritesAreBatchedAndFinalSequenceFlushes() throws {
        var persistedSequences: [Int64] = []
        let start = ContinuousClock().now
        var persistence = EventCursorPersistenceBatch(
            maximumPendingEvents: 128,
            maximumDelay: .seconds(1),
            write: { persistedSequences.append($0) }
        )

        for sequence in 1 ..< 128 {
            try persistence.record(Int64(sequence), now: start)
        }
        #expect(persistedSequences.isEmpty)

        try persistence.record(128, now: start)
        #expect(persistedSequences == [128])

        for sequence in 129 ... 140 {
            try persistence.record(Int64(sequence), now: start)
        }
        try persistence.flush(now: start)
        #expect(persistedSequences == [128, 140])
    }

    @Test func elapsedDelayExposesIdleWakeDeadlineAndFlushes() throws {
        var persistedSequences: [Int64] = []
        let start = ContinuousClock().now
        var persistence = EventCursorPersistenceBatch(
            maximumPendingEvents: 128,
            maximumDelay: .seconds(1),
            write: { persistedSequences.append($0) }
        )

        try persistence.record(41, now: start)
        #expect(persistence.pendingFlushDelay(now: start) == 1)
        try persistence.flushIfDue(now: start.advanced(by: .milliseconds(999)))
        #expect(persistedSequences.isEmpty)
        let remainingDelay = try #require(
            persistence.pendingFlushDelay(now: start.advanced(by: .milliseconds(999)))
        )
        #expect(abs(remainingDelay - 0.001) < 0.000_001)

        try persistence.flushIfDue(now: start.advanced(by: .seconds(1)))
        #expect(persistedSequences == [41])
        #expect(persistence.pendingFlushDelay(now: start.advanced(by: .seconds(1))) == nil)
    }

    @Test func failedWriteRemainsPendingForRetry() throws {
        struct ExpectedFailure: Error {}

        var shouldFail = true
        var persistedSequences: [Int64] = []
        let start = ContinuousClock().now
        var persistence = EventCursorPersistenceBatch(
            maximumPendingEvents: 1,
            maximumDelay: .seconds(1),
            write: { sequence in
                if shouldFail {
                    throw ExpectedFailure()
                }
                persistedSequences.append(sequence)
            }
        )

        #expect(throws: ExpectedFailure.self) {
            try persistence.record(9, now: start)
        }

        shouldFail = false
        try persistence.flush(now: start)
        #expect(persistedSequences == [9])
    }
}
