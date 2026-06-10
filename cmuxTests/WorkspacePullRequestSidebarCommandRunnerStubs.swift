import XCTest
import Darwin
import CmuxProcess

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Command runner stubs for WorkspacePullRequestSidebarTests
/// A `CommandRunning` fake that routes each call through a closure, replacing the
/// former `TabManager.commandRunnerForTesting` static hook.
struct StubCommandRunner: CommandRunning {
    let handler: @Sendable (String, String, [String], TimeInterval?) -> CommandResult
    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        handler(directory, executable, arguments, timeout)
    }
}

final class CommandRunnerInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

final class IndexLockObserver: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "com.cmux.tests.index-lock-observer", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var storedObservationCount = 0

    init(path: String) {
        self.path = path
    }

    func start(pollInterval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: self.path) {
                self.lock.lock()
                self.storedObservationCount += 1
                self.lock.unlock()
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    var observationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedObservationCount
    }
}

final class LockTouchingGitRunner: CommandRunning, @unchecked Sendable {
    private let indexLockPath: String
    private let lock = NSLock()
    private var storedInvocationCount = 0

    init(indexLockPath: String) {
        self.indexLockPath = indexLockPath
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedInvocationCount
    }

    func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
        guard executable == "git" else {
            return CommandResult(
                stdout: "",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }

        lock.lock()
        storedInvocationCount += 1
        lock.unlock()

        FileManager.default.createFile(atPath: indexLockPath, contents: Data(), attributes: nil)
        Thread.sleep(forTimeInterval: 0.15)
        try? FileManager.default.removeItem(atPath: indexLockPath)

        if arguments == ["branch", "--show-current"] {
            return CommandResult(
                stdout: "main\n",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }
        if arguments == ["status", "--porcelain", "-uno"] {
            return CommandResult(
                stdout: "",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }
        if arguments == ["remote", "-v"] {
            return CommandResult(
                stdout: "origin\thttps://github.com/manaflow-ai/cmux.git (fetch)\n",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }
        return CommandResult(
            stdout: "",
            stderr: "unexpected git arguments: \(arguments.joined(separator: " "))",
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        )
    }
}

