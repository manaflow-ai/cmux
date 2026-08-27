import Darwin
import Foundation

/// The outcome of one child process run by ``CLITestProcessRunner``.
///
/// `status` is the exit code for a normal exit and the signal number for a
/// child that died from a signal (the same convention `Process.terminationStatus`
/// uses, so call sites that compare against `SIGTERM`/`SIGKILL` keep working).
struct CLITestProcessOutcome: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

/// Runs CLI children for tests without parking any blocking work on libdispatch.
///
/// The app-host test bundle runs its Swift Testing suites in parallel. The old
/// per-file helpers blocked three libdispatch global-queue workers per child
/// (`waitUntilExit`, and one `readDataToEndOfFile` per output pipe) and every
/// mock socket server parked an `accept` loop plus one blocking reader per
/// client on the same pool. Under parallel execution that exhausts the global
/// worker pool, so the block that is supposed to observe the child's exit never
/// runs and the mock server never answers: the CLI child sits in a socket read,
/// the helper's 5s deadline fires, and the test records
/// `status: 15, timedOut: true` (or `status: 0, timedOut: true` when the child
/// had already exited but nobody could observe it). The app host then keeps
/// those orphaned children alive past the XCTest summary.
///
/// This runner owns the whole child lifecycle on plain POSIX primitives and
/// dedicated threads: `posix_spawn` into its own process group, one reaper
/// thread per child that blocks in `waitpid`, one drain thread per output
/// pipe, and a semaphore the calling test waits on. Nothing here depends on a
/// libdispatch worker being available, so a saturated pool cannot delay exit
/// detection, and a timeout kills the whole process group so a grandchild
/// cannot outlive the test holding the capture pipes open.
enum CLITestProcessRunner {
    /// Runs `executablePath` to completion or until `timeout` elapses.
    ///
    /// - Parameters:
    ///   - standardInput: Written to the child's stdin from a dedicated thread,
    ///     then the write end is closed. `nil` connects stdin to `/dev/null`.
    ///   - outputDrainGrace: How long to wait for the output pipes to reach EOF
    ///     after the child is gone. A grandchild that inherited a pipe can hold
    ///     it open; the captured prefix is returned instead of blocking.
    static func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String? = nil,
        timeout: TimeInterval,
        outputDrainGrace: TimeInterval = 2
    ) -> CLITestProcessOutcome {
        func launchFailure(_ detail: String) -> CLITestProcessOutcome {
            CLITestProcessOutcome(
                status: -1,
                stdout: "",
                stderr: "test runner could not spawn \(executablePath): \(detail)",
                timedOut: false
            )
        }

        var stdinFDs: [Int32] = [-1, -1]
        var stdoutFDs: [Int32] = [-1, -1]
        var stderrFDs: [Int32] = [-1, -1]
        defer {
            for descriptor in stdinFDs + stdoutFDs + stderrFDs where descriptor >= 0 {
                close(descriptor)
            }
        }
        guard pipe(&stdoutFDs) == 0, pipe(&stderrFDs) == 0 else {
            return launchFailure(String(cString: strerror(errno)))
        }
        if standardInput != nil {
            guard pipe(&stdinFDs) == 0 else {
                return launchFailure(String(cString: strerror(errno)))
            }
        }
        guard (stdinFDs + stdoutFDs + stderrFDs).allSatisfy({ $0 < 0 || $0 > STDERR_FILENO }) else {
            return launchFailure("capture pipe collided with standard I/O")
        }

        var fileActions: posix_spawn_file_actions_t?
        var setupStatus = posix_spawn_file_actions_init(&fileActions)
        guard setupStatus == 0 else {
            return launchFailure(String(cString: strerror(setupStatus)))
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        if standardInput == nil {
            setupStatus = "/dev/null".withCString {
                posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, $0, O_RDONLY, 0)
            }
        } else {
            setupStatus = posix_spawn_file_actions_adddup2(&fileActions, stdinFDs[0], STDIN_FILENO)
        }
        if setupStatus == 0 {
            setupStatus = posix_spawn_file_actions_adddup2(&fileActions, stdoutFDs[1], STDOUT_FILENO)
        }
        if setupStatus == 0 {
            setupStatus = posix_spawn_file_actions_adddup2(&fileActions, stderrFDs[1], STDERR_FILENO)
        }
        for descriptor in stdinFDs + stdoutFDs + stderrFDs where setupStatus == 0 && descriptor >= 0 {
            setupStatus = posix_spawn_file_actions_addclose(&fileActions, descriptor)
        }
        guard setupStatus == 0 else {
            return launchFailure(String(cString: strerror(setupStatus)))
        }

        var attributes: posix_spawnattr_t?
        setupStatus = posix_spawnattr_init(&attributes)
        guard setupStatus == 0 else {
            return launchFailure(String(cString: strerror(setupStatus)))
        }
        defer { posix_spawnattr_destroy(&attributes) }
        setupStatus = posix_spawnattr_setpgroup(&attributes, 0)
        if setupStatus == 0 {
            setupStatus = posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
            )
        }
        guard setupStatus == 0 else {
            return launchFailure(String(cString: strerror(setupStatus)))
        }

        let argumentStrings = [executablePath] + arguments
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }.sorted()
        guard (argumentStrings + environmentStrings).allSatisfy({ !$0.utf8.contains(0) }) else {
            return launchFailure("argument or environment contains NUL")
        }
        var argumentPointers = argumentStrings.map { strdup($0) }
        var environmentPointers = environmentStrings.map { strdup($0) }
        defer {
            for pointer in argumentPointers where pointer != nil { free(pointer) }
            for pointer in environmentPointers where pointer != nil { free(pointer) }
        }
        guard argumentPointers.allSatisfy({ $0 != nil }),
              environmentPointers.allSatisfy({ $0 != nil }) else {
            return launchFailure("could not allocate argv or environment")
        }
        argumentPointers.append(nil)
        environmentPointers.append(nil)

        var processIdentifier: pid_t = 0
        let spawnStatus = executablePath.withCString { executablePointer in
            argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
                environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                    guard let argumentBase = argumentBuffer.baseAddress,
                          let environmentBase = environmentBuffer.baseAddress else {
                        return Int32(EINVAL)
                    }
                    return posix_spawn(
                        &processIdentifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentBase,
                        environmentBase
                    )
                }
            }
        }
        guard spawnStatus == 0, processIdentifier > 1 else {
            return launchFailure(String(cString: strerror(spawnStatus == 0 ? ECHILD : spawnStatus)))
        }

        // The child owns its copies now; close ours so EOF propagates.
        close(stdoutFDs[1]); stdoutFDs[1] = -1
        close(stderrFDs[1]); stderrFDs[1] = -1
        if stdinFDs[0] >= 0 {
            close(stdinFDs[0]); stdinFDs[0] = -1
        }

        let stdoutDrain = PipeDrain(descriptor: stdoutFDs[0], name: "cmux-test-stdout-drain")
        stdoutFDs[0] = -1
        let stderrDrain = PipeDrain(descriptor: stderrFDs[0], name: "cmux-test-stderr-drain")
        stderrFDs[0] = -1
        if let standardInput, stdinFDs[1] >= 0 {
            let writeDescriptor = stdinFDs[1]
            stdinFDs[1] = -1
            detachBlockingThread(name: "cmux-test-stdin-writer") {
                writeAll(descriptor: writeDescriptor, data: Data(standardInput.utf8))
                close(writeDescriptor)
            }
        }
        let waiter = ProcessWaiter(processIdentifier: processIdentifier)

        var timedOut = false
        if !waiter.wait(timeout: timeout) {
            timedOut = true
            _ = kill(-processIdentifier, SIGTERM)
            if !waiter.wait(timeout: 1) {
                _ = kill(-processIdentifier, SIGKILL)
                _ = waiter.wait(timeout: 5)
            }
        }

        let stdout = stdoutDrain.text(waitingUpTo: outputDrainGrace)
        let stderr = stderrDrain.text(waitingUpTo: outputDrainGrace)
        guard let status = waiter.status else {
            return CLITestProcessOutcome(
                status: SIGKILL,
                stdout: stdout,
                stderr: stderr.isEmpty
                    ? "test runner could not reap process group after SIGKILL"
                    : "\(stderr)\ntest runner could not reap process group after SIGKILL",
                timedOut: true
            )
        }
        return CLITestProcessOutcome(status: status, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    /// Runs `body` on a dedicated thread instead of a libdispatch global-queue
    /// worker. Use it for anything that blocks indefinitely (accept loops,
    /// blocking socket reads) so parallel tests cannot exhaust the shared pool.
    static func detachBlockingThread(name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.stackSize = 1 << 20
        thread.start()
    }

    private static func writeAll(descriptor: Int32, data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = rawBuffer.count
            var cursor = base
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written > 0 {
                    remaining -= written
                    cursor = cursor.advanced(by: written)
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    /// Reaps one child on a dedicated thread so exit detection never waits for
    /// a libdispatch worker.
    private final class ProcessWaiter: @unchecked Sendable {
        private let processIdentifier: pid_t
        private let lock = NSLock()
        private let finished = DispatchSemaphore(value: 0)
        private var storedStatus: Int32?

        init(processIdentifier: pid_t) {
            self.processIdentifier = processIdentifier
            CLITestProcessRunner.detachBlockingThread(name: "cmux-test-process-reaper") { [self] in
                reap()
            }
        }

        var status: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return storedStatus
        }

        func wait(timeout: TimeInterval) -> Bool {
            if status != nil { return true }
            if finished.wait(timeout: .now() + timeout) == .success { return true }
            // Do not turn a completion racing the deadline into a timeout.
            return status != nil
        }

        private func reap() {
            var rawStatus: Int32 = 0
            var waitResult: pid_t
            repeat {
                waitResult = waitpid(processIdentifier, &rawStatus, 0)
            } while waitResult == -1 && errno == EINTR

            let status: Int32
            if waitResult == processIdentifier {
                let terminatingSignal = rawStatus & 0x7f
                status = terminatingSignal == 0 ? (rawStatus >> 8) & 0xff : terminatingSignal
            } else {
                status = -1
            }
            lock.lock()
            storedStatus = status
            lock.unlock()
            finished.signal()
        }
    }

    /// Reads one pipe to EOF on a dedicated thread so a child writing more than
    /// a pipe buffer never blocks while the test waits for it to exit.
    private final class PipeDrain: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let finished = DispatchSemaphore(value: 0)

        init(descriptor: Int32, name: String) {
            CLITestProcessRunner.detachBlockingThread(name: name) { [self] in
                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 16384)
                while true {
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count > 0 {
                        collected.append(buffer, count: count)
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                close(descriptor)
                lock.lock()
                data = collected
                lock.unlock()
                finished.signal()
            }
        }

        func text(waitingUpTo timeout: TimeInterval) -> String {
            _ = finished.wait(timeout: .now() + timeout)
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
