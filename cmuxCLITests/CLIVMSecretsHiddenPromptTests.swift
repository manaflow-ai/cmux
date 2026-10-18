import Darwin
import Foundation
import Testing

/// Black-box `cmux vm secrets set` at a terminal. The hidden prompt turns echo and
/// canonical mode off, so Ctrl-D, stray control bytes and Ctrl-Z are the CLI's job.
@Suite("cmux vm secrets set hidden prompt", .serialized)
struct CLIVMSecretsHiddenPromptTests {
    @Test("Ctrl-D after typed text ends the value, as in canonical mode")
    func ctrlDAfterInputEndsValue() throws {
        let session = try PromptSession()
        defer { session.close() }
        #expect(session.waitForHiddenInput(), Comment(rawValue: session.transcript))
        session.write("sk-abc\u{04}")
        #expect(session.waitForExit() == 0, Comment(rawValue: session.transcript))
        #expect(session.sentValues == ["sk-abc"])
    }

    @Test("control bytes other than the editing keys never enter the value")
    func controlBytesAreDropped() throws {
        let session = try PromptSession()
        defer { session.close() }
        #expect(session.waitForHiddenInput(), Comment(rawValue: session.transcript))
        session.write("sk\u{1B}-a\tb\u{07}c\u{00}\n")
        #expect(session.waitForExit() == 0, Comment(rawValue: session.transcript))
        #expect(session.sentValues == ["sk-abc"])
    }

    @Test("Ctrl-Z stops the prompt with echo restored, and it reads the value once continued")
    func ctrlZSuspendsAndResumes() throws {
        let session = try PromptSession()
        defer { session.close() }
        #expect(session.waitForHiddenInput(), Comment(rawValue: session.transcript))
        kill(session.pid, SIGTSTP)
        #expect(session.waitForStop(), "SIGTSTP must stop the process, not leave it running")
        #expect(session.echoEnabled, "echo is restored for the shell while the job is stopped")
        kill(session.pid, SIGCONT)
        #expect(session.waitForHiddenInput(), "input is hidden again once the job continues")
        session.write("sk-after\n")
        #expect(session.waitForExit() == 0, Comment(rawValue: session.transcript))
        #expect(session.sentValues == ["sk-after"])
    }
}

/// `cmux vm secrets set OPENAI_API_KEY --no-sync` with all three stdio fds on a
/// pseudo-terminal, against a socket that records the values it is sent.
private final class PromptSession: @unchecked Sendable {
    let pid: pid_t
    private let master: Int32
    private let server: ScriptedVMSocketServer
    private let recorder: ValueRecorder
    private let lock = NSLock()
    private var output = Data()
    private var reaped = false
    private let drained = DispatchSemaphore(value: 0)

    var sentValues: [String] { recorder.values }

    var transcript: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: output, as: UTF8.self)
    }

    var echoEnabled: Bool {
        var settings = termios()
        guard tcgetattr(master, &settings) == 0 else { return false }
        return settings.c_lflag & tcflag_t(ECHO) != 0
    }

    init() throws {
        let recorded = ValueRecorder()
        recorder = recorded
        server = try ScriptedVMSocketServer { method, params in
            guard method == "vm.secrets_set" else { return [:] }
            for entry in (params["entries"] as? [[String: Any]]) ?? [] {
                recorded.append(entry["value"] as? String ?? "")
            }
            return ["changes": []]
        }
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            server.stop()
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(slaveFD) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for target in Int32(0)...2 {
            posix_spawn_file_actions_adddup2(&actions, slaveFD, target)
        }
        // Its own process group in this session, so the group is not orphaned and
        // SIGTSTP's default action really stops it.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signalNumber in [SIGTSTP, SIGCONT, SIGTTIN, SIGTTOU, SIGINT] {
            sigaddset(&defaults, signalNumber)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        let executable = try BundledCLITestSupport.bundledCLIPath()
        let arguments = [executable, "vm", "secrets", "set", "OPENAI_API_KEY", "--no-sync"]
        let environment = [
            "CMUX_SOCKET_PATH=\(server.path)",
            "CMUX_SOCKET_PASSWORD=",
            "CMUX_CLI_SENTRY_DISABLED=1",
            "PATH=\(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")",
        ]
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var spawned: pid_t = 0
        let status = posix_spawn(&spawned, executable, &actions, &attributes, &argv, &envp)
        guard status == 0 else {
            Darwin.close(masterFD)
            server.stop()
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        pid = spawned
        master = masterFD

        // Keep the master drained so the CLI never blocks writing its prompt.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(master, &buffer, buffer.count)
                if count > 0 {
                    lock.lock()
                    output.append(buffer, count: count)
                    lock.unlock()
                    continue
                }
                if count < 0, errno == EINTR { continue }
                break
            }
            drained.signal()
        }
    }

    /// True once the prompt has turned echo and canonical mode off, which happens
    /// after its signal handlers are installed.
    func waitForHiddenInput(timeout: TimeInterval = 10) -> Bool {
        poll(timeout: timeout) {
            var settings = termios()
            guard tcgetattr(master, &settings) == 0 else { return false }
            return settings.c_lflag & tcflag_t(ECHO | ICANON) == 0
        }
    }

    func write(_ text: String) {
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBufferPointer { Darwin.write(master, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            written += count
        }
    }

    func waitForStop(timeout: TimeInterval = 10) -> Bool {
        poll(timeout: timeout) {
            var status: Int32 = 0
            return waitpid(pid, &status, WUNTRACED | WNOHANG) == pid && (status & 0xFF) == 0x7F
        }
    }

    /// The exit status, or nil if the CLI is still running at the deadline.
    func waitForExit(timeout: TimeInterval = 10) -> Int32? {
        var exitStatus: Int32?
        _ = poll(timeout: timeout) {
            var status: Int32 = 0
            guard waitpid(pid, &status, WNOHANG) == pid else { return false }
            exitStatus = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            return true
        }
        if exitStatus != nil {
            lock.lock()
            reaped = true
            lock.unlock()
            _ = drained.wait(timeout: .now() + 2)
        }
        return exitStatus
    }

    func close() {
        lock.lock()
        let running = !reaped
        lock.unlock()
        if running {
            kill(pid, SIGKILL)
            kill(pid, SIGCONT)
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }
        Darwin.close(master)
        server.stop()
    }

    private func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }
}

/// The values `vm.secrets_set` received, written from the socket thread.
private final class ValueRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ value: String) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }
}
