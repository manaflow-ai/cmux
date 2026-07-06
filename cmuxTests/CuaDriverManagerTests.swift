import Darwin
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
              elif [[ "$line" == *'"method":"tools/list"'* ]]; then
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
              elif [[ "$line" == *'"method":"tools/list"'* ]]; then
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
              elif [[ "$line" == *'"method":"tools/list"'* ]]; then
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
