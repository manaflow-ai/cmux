import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/12681.
///
/// The CLI runs its commands on Swift concurrency threads. On macOS those
/// threads carry a nearly full signal mask, and `execve` hands the calling
/// thread's mask to the new image. `cmux restore` therefore launched resumed
/// agents with SIGWINCH blocked: Codex and Claude Code never received a resize
/// event again, kept painting at their startup width, and garbled on the first
/// pane resize. Every CLI exec goes through `cliExecFailureErrno`, so the child
/// it produces must start from the default signal state, and every exec or
/// `posix_spawn` site under `CLI/` must use that wrapper or the equivalent
/// spawn attributes: `cmux restore` and `cmux fork` exec the resumed agent from
/// their own files.
@Suite struct CLIExecInheritedSignalStateTests {
    private typealias ForkFunction = @convention(c) () -> pid_t

    private struct ChildSignalState {
        let blockedSignals: [Int32]
        let ignoresWindowChange: Bool
    }

    @Test func execFromConcurrencyThreadHandsChildDefaultSignalState() async throws {
        try #require(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
            "The probe child needs /usr/bin/python3"
        )
        // A detached task runs on the cooperative pool, the same kind of
        // thread `static func main() async` gives every CLI command.
        let state = try await Task.detached(priority: .userInitiated) {
            try Self.childSignalStateAfterCLIExec()
        }.value
        #expect(
            !state.blockedSignals.contains(SIGWINCH),
            "SIGWINCH stayed blocked across the CLI exec: \(state.blockedSignals)"
        )
        #expect(
            state.blockedSignals.isEmpty,
            "The exec'd child inherited a blocked signal mask: \(state.blockedSignals)"
        )
        #expect(!state.ignoresWindowChange, "The exec'd child inherited SIG_IGN for SIGWINCH")
    }

    /// The exec wrapper only protects the sites that call it. `cmux restore`
    /// and `cmux fork` exec the resumed agent from their own files, so one
    /// direct `execve` hands the agent the blocked mask again. Every exec under
    /// `CLI/` must run inside `cliExecFailureErrno`, and every `posix_spawn`
    /// must set `POSIX_SPAWN_SETSIGMASK`.
    @Test func everyCLIExecAndSpawnSiteStartsChildrenFromDefaultSignalState() throws {
        let cliDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CLI", isDirectory: true)
        let fileNames = try FileManager.default.contentsOfDirectory(atPath: cliDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        try #require(!fileNames.isEmpty, "no CLI sources under \(cliDirectory.path)")

        let execCall = try Regex(#"\b(execve|execv|execvp|execvP|execl|execle|execlp)\("#)
        let spawnCall = try Regex(#"\bposix_spawnp?\("#)
        var unguardedExecSites: [String] = []
        var unguardedSpawnSites: [String] = []
        for fileName in fileNames {
            let path = cliDirectory.appendingPathComponent(fileName).path
            let lines = try String(contentsOfFile: path, encoding: .utf8)
                .components(separatedBy: "\n")
            let source = lines.joined(separator: "\n")
            let spawnSetsMask = source.contains("POSIX_SPAWN_SETSIGMASK")
                && source.contains("posix_spawnattr_setsigmask(")
            for (index, line) in lines.enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if line.contains(execCall) {
                    let precedingLines = lines[max(0, index - 12)..<index]
                    if !precedingLines.contains(where: { $0.contains("cliExecFailureErrno") }) {
                        unguardedExecSites.append("\(fileName):\(index + 1)")
                    }
                }
                if line.contains(spawnCall), !spawnSetsMask {
                    unguardedSpawnSites.append("\(fileName):\(index + 1)")
                }
            }
        }
        #expect(
            unguardedExecSites.isEmpty,
            "exec sites outside cliExecFailureErrno hand the child the thread's signal mask: \(unguardedExecSites)"
        )
        #expect(
            unguardedSpawnSites.isEmpty,
            "posix_spawn sites without POSIX_SPAWN_SETSIGMASK hand the child the thread's signal mask: \(unguardedSpawnSites)"
        )
    }

    /// Forks a child on the current thread and replaces it through the CLI's
    /// exec path with a probe that reports the signal state it started with.
    private static func childSignalStateAfterCLIExec() throws -> ChildSignalState {
        // Make the hazard explicit instead of relying on the runtime's thread
        // mask: block SIGWINCH on this thread and ignore it process-wide, as a
        // CLI command that installed a DispatchSource signal monitor does.
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGWINCH)
        var previousMask = sigset_t()
        try #require(pthread_sigmask(SIG_BLOCK, &blocked, &previousMask) == 0)
        defer { pthread_sigmask(SIG_SETMASK, &previousMask, nil) }
        let previousDisposition = signal(SIGWINCH, SIG_IGN)
        defer { _ = signal(SIGWINCH, previousDisposition) }

        var pipeDescriptors: [Int32] = [-1, -1]
        try #require(pipe(&pipeDescriptors) == 0)
        let readEnd = pipeDescriptors[0]
        let writeEnd = pipeDescriptors[1]

        let probe = """
        import signal
        blocked = sorted(int(s) for s in signal.pthread_sigmask(signal.SIG_BLOCK, []))
        ignored = int(signal.getsignal(signal.SIGWINCH) == signal.SIG_IGN)
        print("blocked=%s ignored=%d" % (",".join(map(str, blocked)) or "-", ignored))
        """
        let executable = "/usr/bin/python3"
        // Prepare every C string before forking so the child only dups,
        // execs, and exits.
        var argv: [UnsafeMutablePointer<CChar>?] = [executable, "-c", probe].map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        // Swift marks `fork` unavailable; the child does nothing but dup2 and
        // exec, which is the one pattern fork is still safe for.
        let forkSymbol = try #require(dlsym(dlopen(nil, RTLD_NOW), "fork"))
        let fork = unsafeBitCast(forkSymbol, to: ForkFunction.self)
        let child = executable.withCString { path -> pid_t in
            let pid = fork()
            guard pid == 0 else { return pid }
            _ = dup2(writeEnd, STDOUT_FILENO)
            _ = close(readEnd)
            _ = close(writeEnd)
            _ = argv.withUnsafeMutableBufferPointer { buffer in
                cliExecFailureErrno {
                    _ = execv(path, buffer.baseAddress)
                }
            }
            _exit(126)
        }
        _ = close(writeEnd)
        try #require(child > 0, "fork failed: \(String(cString: strerror(errno)))")

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 512)
        while true {
            let count = read(readEnd, &chunk, chunk.count)
            if count > 0 {
                output.append(contentsOf: chunk[0..<count])
                continue
            }
            if count < 0 && errno == EINTR { continue }
            break
        }
        _ = close(readEnd)
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        let exitedNormally = (status & 0x7f) == 0
        let exitStatus = (status >> 8) & 0xff
        try #require(exitedNormally && exitStatus == 0, "probe exited with status \(status)")

        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = Dictionary(
            uniqueKeysWithValues: text.split(separator: " ").compactMap { field -> (String, String)? in
                let parts = field.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            }
        )
        let blockedField = try #require(fields["blocked"], "probe output: \(text)")
        let ignoredField = try #require(fields["ignored"], "probe output: \(text)")
        let blockedSignals = blockedField == "-"
            ? []
            : blockedField.split(separator: ",").compactMap { Int32($0) }
        return ChildSignalState(
            blockedSignals: blockedSignals,
            ignoresWindowChange: ignoredField == "1"
        )
    }
}
