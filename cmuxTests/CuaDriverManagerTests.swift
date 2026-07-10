import Darwin
import Dispatch
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV

@MainActor
final class CuaDriverManagerTests: XCTestCase {
    func testHandshakeReachesRunningAndStopTerminatesChild() async throws {
        let executable = try makeStubExecutable(
            name: "cua-driver-success",
            body: """
            while IFS= read -r line; do
              if [[ "$line" == *'"method":"initialize"'* ]]; then
                printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","serverInfo":{"name":"stub-cua","version":"0.1"}}}'
              elif [[ "$line" == *'"id":2'* ]]; then
                printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"one"},{"name":"two"}]}}'
              fi
            done
            """
        )
        let manager = CuaDriverManager(registerTerminationObserver: false)
        let updates = CuaDriverStateUpdateIterator(manager.stateUpdates())
        let first = await updates.next()
        XCTAssertEqual(first, .stopped)

        let startTask = Task { @MainActor in
            await manager.start(
                settingValue: executable.path,
                environment: [:],
                bundleHelperURL: URL(fileURLWithPath: "/tmp/missing-cua-driver"),
                fileExists: { $0.path == executable.path }
            )
        }

        let starting = await nextState(from: updates, matching: { $0 == .starting })
        XCTAssertEqual(starting, .starting)
        let nextRunning = await nextState(from: updates, matching: {
            if case .running = $0 { return true }
            return false
        })
        let running = try XCTUnwrap(nextRunning)
        await startTask.value

        guard case let .running(info) = running else {
            XCTFail("Expected running state")
            return
        }
        XCTAssertEqual(info.serverName, "stub-cua")
        XCTAssertEqual(info.serverVersion, "0.1")
        XCTAssertEqual(info.toolCount, 2)
        XCTAssertEqual(kill(info.pid, 0), 0)

        await manager.stop()
        XCTAssertEqual(manager.state, .stopped)
        XCTAssertNotEqual(kill(info.pid, 0), 0)
    }

    func testImmediateExitBecomesFailed() async throws {
        let executable = try makeStubExecutable(
            name: "cua-driver-exit",
            body: "exit 7"
        )
        let manager = CuaDriverManager(registerTerminationObserver: false)
        let updates = CuaDriverStateUpdateIterator(manager.stateUpdates())
        _ = await updates.next()

        await manager.start(
            settingValue: executable.path,
            environment: [:],
            bundleHelperURL: URL(fileURLWithPath: "/tmp/missing-cua-driver"),
            fileExists: { $0.path == executable.path }
        )

        if case .failed = manager.state {
            return
        }
        let failed = await nextState(from: updates, matching: {
            if case .failed = $0 { return true }
            return false
        })
        guard case .failed = failed else {
            XCTFail("Expected failed state, got \(String(describing: failed))")
            return
        }
    }

    func testStartPassesSkyCursorArguments() async throws {
        let directory = try makeTemporaryDirectory()
        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let executable = try makeStubExecutable(
            name: "cua-driver-arguments",
            directory: directory,
            body: """
            printf '%s\\n' "$*" > \(shellQuoted(argumentsFile.path))
            while IFS= read -r line; do
              if [[ "$line" == *'"method":"initialize"'* ]]; then
                printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","serverInfo":{"name":"stub-cua","version":"0.1"}}}'
              elif [[ "$line" == *'"id":2'* ]]; then
                printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"one"}]}}'
              fi
            done
            """
        )
        let manager = CuaDriverManager(registerTerminationObserver: false)

        await manager.start(
            settingValue: executable.path,
            environment: [:],
            bundleHelperURL: URL(fileURLWithPath: "/tmp/missing-cua-driver"),
            fileExists: { $0.path == executable.path }
        )

        guard case .running = manager.state else {
            XCTFail("Expected running state, got \(manager.state)")
            return
        }
        XCTAssertEqual(try readRecordedLines(from: argumentsFile), ["mcp --no-daemon-relaunch --cursor-shape sky"])
        await manager.stop()
    }

    func testFallsBackWithoutCursorArgumentsWhenFirstAttemptExitsBeforeHandshake() async throws {
        let directory = try makeTemporaryDirectory()
        let attemptsFile = directory.appendingPathComponent("attempts.txt")
        let executable = try makeStubExecutable(
            name: "cua-driver-fallback",
            directory: directory,
            body: """
            printf '%s\\n' "$*" >> \(shellQuoted(attemptsFile.path))
            if [[ " $* " == *" --cursor-shape "* ]]; then
              printf '%s\\n' "error: invalid value 'sky' for '--cursor-shape <CURSOR_SHAPE>'" >&2
              exit 2
            fi
            while IFS= read -r line; do
              if [[ "$line" == *'"method":"initialize"'* ]]; then
                printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","serverInfo":{"name":"stub-cua","version":"0.1"}}}'
              elif [[ "$line" == *'"id":2'* ]]; then
                printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"one"},{"name":"two"}]}}'
              fi
            done
            """
        )
        let manager = CuaDriverManager(registerTerminationObserver: false)

        await manager.start(
            settingValue: executable.path,
            environment: [:],
            bundleHelperURL: URL(fileURLWithPath: "/tmp/missing-cua-driver"),
            fileExists: { $0.path == executable.path }
        )

        guard case let .running(info) = manager.state else {
            XCTFail("Expected running state, got \(manager.state)")
            return
        }
        XCTAssertEqual(info.toolCount, 2)
        XCTAssertEqual(try readRecordedLines(from: attemptsFile), [
            "mcp --no-daemon-relaunch --cursor-shape sky",
            "mcp --no-daemon-relaunch",
        ])
        await manager.stop()
    }

    func testEnsureReturnsRunningProcessWithoutRespawning() async throws {
        let directory = try makeTemporaryDirectory()
        let invocationsFile = directory.appendingPathComponent("invocations.txt")
        let executable = try makeStubExecutable(
            name: "cua-driver-ensure-idempotent",
            directory: directory,
            body: """
            printf '%s\\n' invocation >> \(shellQuoted(invocationsFile.path))
            while IFS= read -r line; do
              if [[ "$line" == *'"method":"initialize"'* ]]; then
                printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","serverInfo":{"name":"stub-cua","version":"0.1"}}}'
              elif [[ "$line" == *'"id":2'* ]]; then
                printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"one"}]}}'
              fi
            done
            """
        )
        let manager = CuaDriverManager(registerTerminationObserver: false)

        let firstResult = await manager.ensure(
            settingValue: executable.path,
            environment: [:],
            bundleHelperURL: URL(fileURLWithPath: "/tmp/missing-cua-driver"),
            fileExists: { $0.path == executable.path }
        )
        let first = try XCTUnwrap(firstResult)
        let secondResult = await manager.ensure(
            settingValue: executable.path,
            environment: [:],
            bundleHelperURL: URL(fileURLWithPath: "/tmp/missing-cua-driver"),
            fileExists: { $0.path == executable.path }
        )
        let second = try XCTUnwrap(secondResult)

        XCTAssertEqual(second.pid, first.pid)
        XCTAssertEqual(try readRecordedLines(from: invocationsFile), ["invocation"])
        await manager.stop()
    }

    func testEnsureRetriesAfterFailedStart() async throws {
        let directory = try makeTemporaryDirectory()
        let invocationsFile = directory.appendingPathComponent("invocations.txt")
        let executable = try makeStubExecutable(
            name: "cua-driver-ensure-retry",
            directory: directory,
            body: """
            printf '%s\\n' invocation >> \(shellQuoted(invocationsFile.path))
            attempt=$(wc -l < \(shellQuoted(invocationsFile.path)))
            if (( attempt <= 2 )); then
              exit 7
            fi
            while IFS= read -r line; do
              if [[ "$line" == *'"method":"initialize"'* ]]; then
                printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","serverInfo":{"name":"stub-cua","version":"0.2"}}}'
              elif [[ "$line" == *'"id":2'* ]]; then
                printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"one"},{"name":"two"}]}}'
              fi
            done
            """
        )
        let manager = CuaDriverManager(registerTerminationObserver: false)

        let failedResult = await manager.ensure(
            settingValue: executable.path,
            environment: [:],
            bundleHelperURL: URL(fileURLWithPath: "/tmp/missing-cua-driver"),
            fileExists: { $0.path == executable.path }
        )
        XCTAssertNil(failedResult)
        guard case .failed = manager.state else {
            XCTFail("Expected failed state, got \(manager.state)")
            return
        }

        let retriedResult = await manager.ensure(
            settingValue: executable.path,
            environment: [:],
            bundleHelperURL: URL(fileURLWithPath: "/tmp/missing-cua-driver"),
            fileExists: { $0.path == executable.path }
        )
        let retried = try XCTUnwrap(retriedResult)
        XCTAssertEqual(retried.serverVersion, "0.2")
        XCTAssertEqual(retried.toolCount, 2)
        XCTAssertEqual(try readRecordedLines(from: invocationsFile).count, 3)
        await manager.stop()
    }

    func testLineStreamSplitsLinesTrimsCarriageReturnsAndFlushesEOF() async throws {
        let pipe = Pipe()
        let inbox = CuaDriverLineInbox(stream: CuaDriverLineStream.lines(from: pipe.fileHandleForReading))

        try pipe.fileHandleForWriting.write(contentsOf: Data("first\r\n".utf8))
        let first = try await inbox.nextLine()
        try pipe.fileHandleForWriting.write(contentsOf: Data("second\npartial".utf8))
        pipe.fileHandleForWriting.closeFile()
        let second = try await inbox.nextLine()
        let partial = try await inbox.nextLine()
        let eof = try await inbox.nextLine()
        XCTAssertEqual(first, "first")
        XCTAssertEqual(second, "second")
        XCTAssertEqual(partial, "partial")
        XCTAssertNil(eof)
        pipe.fileHandleForReading.closeFile()
    }

    func testLineStreamRejectsInvalidUTF8() async throws {
        let pipe = Pipe()
        let inbox = CuaDriverLineInbox(stream: CuaDriverLineStream.lines(from: pipe.fileHandleForReading))

        try pipe.fileHandleForWriting.write(contentsOf: Data([0xFF]))
        pipe.fileHandleForWriting.closeFile()

        do {
            _ = try await inbox.nextLine()
            XCTFail("Expected invalid UTF-8 to fail the line stream")
        } catch CuaDriverManagerError.invalidUTF8 {
            // Expected.
        } catch {
            XCTFail("Expected invalidUTF8, got \(error)")
        }
        pipe.fileHandleForReading.closeFile()
    }

    func testTerminationInboxWaitIsCancellationAware() async {
        let inbox = CuaDriverTerminationInbox()
        let waiter = Task {
            try await inbox.next()
        }
        await Task.yield()
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testEnsureDuringInFlightFailingStartNeverLeavesStarting() async throws {
        let directory = try makeTemporaryDirectory()
        let attemptsFile = directory.appendingPathComponent("attempts.txt")
        let releaseFIFO = directory.appendingPathComponent("release.fifo")
        XCTAssertEqual(mkfifo(releaseFIFO.path, 0o600), 0)
        let executable = try makeStubExecutable(
            name: "cua-driver-concurrent-failure",
            directory: directory,
            body: """
            printf '%s\\n' "$*" >> \(shellQuoted(attemptsFile.path))
            attempt=$(wc -l < \(shellQuoted(attemptsFile.path)))
            if (( attempt == 1 )); then
              IFS= read -r _ < \(shellQuoted(releaseFIFO.path))
            fi
            printf '%s\\n' "error: rejected test arguments" >&2
            exit 2
            """
        )
        let manager = CuaDriverManager(registerTerminationObserver: false)
        let updates = CuaDriverStateUpdateIterator(manager.stateUpdates())
        _ = await updates.next()

        let firstEnsure = Task { @MainActor in
            await manager.ensure(
                settingValue: executable.path,
                environment: [:],
                bundleHelperURL: URL(fileURLWithPath: "/tmp/missing-cua-driver"),
                fileExists: { $0.path == executable.path }
            )
        }
        let starting = await nextState(from: updates, matching: { $0 == .starting })
        XCTAssertEqual(starting, .starting)

        let fifoPath = releaseFIFO.path
        let releaseTask = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let descriptor = open(fifoPath, O_WRONLY)
                    guard descriptor >= 0 else {
                        continuation.resume(returning: -1)
                        return
                    }
                    var byte: UInt8 = 0x0A
                    let written = withUnsafeBytes(of: &byte) { bytes in
                        write(descriptor, bytes.baseAddress, bytes.count)
                    }
                    close(descriptor)
                    continuation.resume(returning: written)
                }
            }
        }
        let secondResult = await manager.ensure(
            settingValue: executable.path,
            environment: [:],
            bundleHelperURL: URL(fileURLWithPath: "/tmp/missing-cua-driver"),
            fileExists: { $0.path == executable.path }
        )

        let releasedBytes = await releaseTask.value
        let firstResult = await firstEnsure.value
        XCTAssertEqual(releasedBytes, 1)
        XCTAssertNil(secondResult)
        XCTAssertNil(firstResult)
        guard case .failed = manager.state else {
            XCTFail("Expected failed state, got \(manager.state)")
            return
        }
        XCTAssertEqual(try readRecordedLines(from: attemptsFile).count, 2)

        let retryResult = await manager.ensure(
            settingValue: executable.path,
            environment: [:],
            bundleHelperURL: URL(fileURLWithPath: "/tmp/missing-cua-driver"),
            fileExists: { $0.path == executable.path }
        )
        XCTAssertNil(retryResult)
        guard case .failed = manager.state else {
            XCTFail("Expected retry to end failed, got \(manager.state)")
            return
        }
        XCTAssertEqual(try readRecordedLines(from: attemptsFile).count, 4)
    }

    private func nextState(
        from updates: CuaDriverStateUpdateIterator,
        matching predicate: @escaping @Sendable (CuaDriverManager.State) -> Bool
    ) async -> CuaDriverManager.State? {
        let readTask = Task { @MainActor () -> CuaDriverManager.State? in
            while let state = await updates.next() {
                if predicate(state) {
                    return state
                }
            }
            return nil
        }

        let clock = ContinuousClock()
        let result = await withTaskGroup(of: NextStateResult.self) { group in
            group.addTask {
                .state(await readTask.value)
            }
            group.addTask {
                do {
                    try await clock.sleep(for: .seconds(10))
                } catch {
                    return .timeout
                }
                return .timeout
            }

            guard let result = await group.next() else {
                readTask.cancel()
                group.cancelAll()
                return NextStateResult.timeout
            }
            if case .timeout = result {
                readTask.cancel()
            }
            group.cancelAll()
            return result
        }

        switch result {
        case .state(let state):
            return state
        case .timeout:
            XCTFail("Timed out waiting for cua-driver state update.")
            return nil
        }
    }

    private func makeStubExecutable(name: String, directory providedDirectory: URL? = nil, body: String) throws -> URL {
        let directory: URL
        if let providedDirectory {
            directory = providedDirectory
        } else {
            directory = try makeTemporaryDirectory()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let script = """
        #!/bin/bash
        \(body)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuaDriverManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func readRecordedLines(from url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

@MainActor
private final class CuaDriverStateUpdateIterator {
    private var iterator: AsyncStream<CuaDriverManager.State>.Iterator

    init(_ stream: AsyncStream<CuaDriverManager.State>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async -> CuaDriverManager.State? {
        var current = iterator
        let value = await current.next()
        iterator = current
        return value
    }
}

private enum NextStateResult {
    case state(CuaDriverManager.State?)
    case timeout
}
#endif
