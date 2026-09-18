import Darwin
import Foundation

struct CLIRunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Runs the CLI binary to completion with a hard timeout, so a hung invocation
/// fails the test instead of stalling the suite.
///
/// Three properties a plain `Process` + `readDataToEndOfFile` pair cannot give,
/// each of which had already produced a stalled or leaky run:
///
/// * **Its own process group.** The CLI spawns detached helpers (the auto-naming
///   and resume hook spawners). Terminating only the leader on timeout left those
///   descendants running past the end of the test.
/// * **Concurrently drained pipes.** Reading only after exit deadlocks two ways:
///   a child that fills a pipe buffer blocks *before* it can exit, and a detached
///   helper that inherited a write end keeps the pipe open after the leader is
///   reaped, so the read never reaches EOF. Both stall the whole suite, which is
///   the one thing the timeout above exists to prevent.
/// * **A hermetic home.** Every invocation gets a fresh `HOME` and
///   `CFFIXED_USER_HOME`, so a facade regression that reads or writes user state
///   cannot touch the developer's real `~/.local/state/cmux` or config.
func runCLI(
    _ cliPath: String,
    arguments: [String],
    environment: [String: String]
) throws -> CLIRunResult {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    var environmentVariables = ProcessInfo.processInfo.environment
    // Every cmux-owned variable, not a hand-kept allowlist: an ambient
    // CMUX_SOCKET_PATH points the child at the developer's running app, and
    // CMUX_CLI_LEGACY_PARSER silently routes it around the facade under test.
    for key in Array(environmentVariables.keys) where key.hasPrefix("CMUX_") || key.hasPrefix("CMUXD_") {
        environmentVariables.removeValue(forKey: key)
    }
    environmentVariables["CMUX_CLI_SENTRY_DISABLED"] = "1"
    environmentVariables["HOME"] = home.path
    environmentVariables["CFFIXED_USER_HOME"] = home.path
    environmentVariables.merge(environment) { _, new in new }

    let launched = try spawnCLIProcessGroup(
        executablePath: cliPath,
        arguments: arguments,
        environment: environmentVariables
    )

    guard launched.waiter.wait(timeout: 5) else {
        // Signal the group, not the leader: descendants that inherited the group
        // are what would otherwise outlive the test.
        _ = Darwin.kill(-launched.processIdentifier, SIGTERM)
        if !launched.waiter.wait(timeout: 1) {
            _ = Darwin.kill(-launched.processIdentifier, SIGKILL)
            _ = launched.waiter.wait(timeout: 1)
        }
        // The drains are already running, so whatever the child managed to write
        // is available for the failure message.
        throw NSError(
            domain: "CLIProcessRunSupport",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: """
                    cmux \(arguments.joined(separator: " ")) timed out
                    stdout: \(launched.stdout.text(waitingUpTo: 1))
                    stderr: \(launched.stderr.text(waitingUpTo: 1))
                    """,
            ]
        )
    }

    // The leader is reaped, so its pipe ends are closed and each drain sees EOF.
    // The ceiling covers a detached helper still holding a write end: report what
    // was read rather than block the suite on a pipe that may never close.
    return CLIRunResult(
        exitCode: launched.waiter.exitCode ?? -1,
        stdout: launched.stdout.text(waitingUpTo: 5).trimmingCharacters(in: .whitespacesAndNewlines),
        stderr: launched.stderr.text(waitingUpTo: 5).trimmingCharacters(in: .whitespacesAndNewlines)
    )
}

private func temporaryHome() throws -> URL {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cmux-cli-test-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private struct LaunchedCLIProcess {
    let processIdentifier: pid_t
    let waiter: CLIProcessWaiter
    let stdout: CLIPipeDrain
    let stderr: CLIPipeDrain
}

private func spawnCLIProcessGroup(
    executablePath: String,
    arguments: [String],
    environment: [String: String]
) throws -> LaunchedCLIProcess {
    func failure(_ detail: String) -> NSError {
        NSError(
            domain: "CLIProcessRunSupport",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "could not spawn \(executablePath): \(detail)"]
        )
    }

    var stdoutFDs: [Int32] = [-1, -1]
    var stderrFDs: [Int32] = [-1, -1]
    var openFDs: Set<Int32> = []
    defer {
        for descriptor in openFDs where descriptor >= 0 { close(descriptor) }
    }
    guard pipe(&stdoutFDs) == 0, pipe(&stderrFDs) == 0 else {
        throw failure(String(cString: strerror(errno)))
    }
    openFDs = Set(stdoutFDs + stderrFDs)

    var fileActions: posix_spawn_file_actions_t?
    var status = posix_spawn_file_actions_init(&fileActions)
    guard status == 0 else { throw failure(String(cString: strerror(status))) }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    status = "/dev/null".withCString {
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, $0, O_RDONLY, 0)
    }
    if status == 0 {
        status = posix_spawn_file_actions_adddup2(&fileActions, stdoutFDs[1], STDOUT_FILENO)
    }
    if status == 0 {
        status = posix_spawn_file_actions_adddup2(&fileActions, stderrFDs[1], STDERR_FILENO)
    }
    guard status == 0 else { throw failure(String(cString: strerror(status))) }

    var attributes: posix_spawnattr_t?
    status = posix_spawnattr_init(&attributes)
    guard status == 0 else { throw failure(String(cString: strerror(status))) }
    defer { posix_spawnattr_destroy(&attributes) }
    // pgroup 0 makes the child the leader of a new group, so `kill(-pid, ...)`
    // reaches every descendant that has not deliberately left it.
    status = posix_spawnattr_setpgroup(&attributes, 0)
    if status == 0 {
        status = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
        )
    }
    guard status == 0 else { throw failure(String(cString: strerror(status))) }

    let argumentStrings = [executablePath] + arguments
    let environmentStrings = environment.map { "\($0.key)=\($0.value)" }.sorted()
    guard (argumentStrings + environmentStrings).allSatisfy({ !$0.utf8.contains(0) }) else {
        throw failure("argument or environment contains NUL")
    }
    var argumentPointers = argumentStrings.map { strdup($0) }
    var environmentPointers = environmentStrings.map { strdup($0) }
    defer {
        for pointer in argumentPointers where pointer != nil { free(pointer) }
        for pointer in environmentPointers where pointer != nil { free(pointer) }
    }
    guard argumentPointers.allSatisfy({ $0 != nil }),
          environmentPointers.allSatisfy({ $0 != nil }) else {
        throw failure("could not allocate argv or environment")
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
        throw failure(String(cString: strerror(spawnStatus == 0 ? ECHILD : spawnStatus)))
    }

    // Close the parent's copies of the write ends first: while the parent still
    // holds one, the reader never sees EOF even after the child exits.
    close(stdoutFDs[1]); openFDs.remove(stdoutFDs[1])
    close(stderrFDs[1]); openFDs.remove(stderrFDs[1])
    let stdoutDrain = CLIPipeDrain(fileDescriptor: stdoutFDs[0])
    openFDs.remove(stdoutFDs[0])
    let stderrDrain = CLIPipeDrain(fileDescriptor: stderrFDs[0])
    openFDs.remove(stderrFDs[0])

    return LaunchedCLIProcess(
        processIdentifier: processIdentifier,
        waiter: CLIProcessWaiter(processIdentifier: processIdentifier),
        stdout: stdoutDrain,
        stderr: stderrDrain
    )
}

/// Reaps the spawned leader on a dedicated thread so callers can wait with a
/// deadline instead of blocking in `waitpid`.
private final class CLIProcessWaiter: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var status: Int32?

    init(processIdentifier: pid_t) {
        let thread = Thread { [self] in
            var raw: Int32 = 0
            while waitpid(processIdentifier, &raw, 0) < 0 && errno == EINTR { continue }
            lock.lock()
            status = raw
            lock.unlock()
            finished.signal()
        }
        thread.stackSize = 512 << 10
        thread.start()
    }

    func wait(timeout seconds: TimeInterval) -> Bool {
        guard finished.wait(timeout: .now() + seconds) == .success else { return false }
        finished.signal()
        return true
    }

    /// The child's exit code, or the negated signal number if it was killed.
    var exitCode: Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let status else { return nil }
        if status & 0x7f == 0 { return (status >> 8) & 0xff }
        return -(status & 0x7f)
    }
}

/// Reads one pipe on its own thread from the moment the child starts, so a child
/// that outruns the pipe buffer never blocks waiting for a reader that is itself
/// waiting for the child to exit.
private final class CLIPipeDrain: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var buffer = Data()

    init(fileDescriptor: Int32) {
        let thread = Thread { [self] in
            var chunk = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let count = chunk.withUnsafeMutableBytes { pointer in
                    read(fileDescriptor, pointer.baseAddress, pointer.count)
                }
                if count > 0 {
                    lock.lock()
                    buffer.append(contentsOf: chunk[0..<count])
                    lock.unlock()
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                break
            }
            close(fileDescriptor)
            finished.signal()
        }
        thread.stackSize = 512 << 10
        thread.start()
    }

    /// Everything read so far, waiting up to `seconds` for the pipe to reach EOF.
    func text(waitingUpTo seconds: TimeInterval) -> String {
        if finished.wait(timeout: .now() + seconds) == .success {
            finished.signal()
        }
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}
