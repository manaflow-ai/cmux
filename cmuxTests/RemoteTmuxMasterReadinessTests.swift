import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the shared-ControlMaster readiness gate that fixes the
/// "only ~2 of N sessions mirror on first attach" race
/// (https://github.com/manaflow-ai/cmux/issues/6732).
///
/// The bug: ``RemoteTmuxController`` fires the per-session `tmux -CC attach`
/// connections (each `ControlMaster=auto`) in a tight burst. On a cold first
/// attach they all race to *create* the master at the same `ControlPath`; all but
/// one fail with "ControlSocket … already exists, disabling multiplexing", so only
/// one or two sessions mirror. The fix —
/// ``RemoteTmuxSSHTransport/ensureMasterReady()`` — opens the master exactly once (a
/// single connection can't lose the creation race); a successful open IS the
/// readiness signal (the mux connection was accepted and `ControlPersist` keeps the
/// master alive), so the burst rides a live master.
///
/// The OpenSSH creation race itself isn't hermetically reproducible (it needs a
/// real multi-session host), so these tests lock in the *mechanism* that prevents
/// it: a fake `ssh` that records its invocations and tracks a master-up sentinel,
/// asserting the gate opens the master once when cold, is idempotent when warm,
/// reports not-ready (so callers degrade) when the open fails, and aborts on caller
/// cancellation instead of hanging.
@Suite struct RemoteTmuxMasterReadinessTests {

    @Test func coldOpenSignalsReadinessAndOpensExactlyOnce() async throws {
        let env = try FakeSSHEnvironment(behavior: .opensOnFirstRun)
        defer { env.cleanUp() }

        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        let ready = try await transport.ensureMasterReady()

        #expect(ready)
        // The master must be opened exactly once — a single creator can't lose the
        // burst's creation race. More than one open would reintroduce it.
        #expect(env.openCount() == 1)
        // A successful open is the readiness signal: no `ssh -O check` confirmation
        // is issued afterward (only the one initial warm-path probe runs).
        #expect(env.checkCount() == 1)
    }

    @Test func warmMasterShortCircuitsWithoutReopening() async throws {
        let env = try FakeSSHEnvironment(behavior: .alreadyRunning)
        defer { env.cleanUp() }

        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        let ready = try await transport.ensureMasterReady()

        #expect(ready)
        // Already-live master (e.g. just opened by discovery): confirmed by the
        // first check, never re-opened.
        #expect(env.openCount() == 0)
    }

    @Test func failedMasterOpenReportsNotReady() async throws {
        let env = try FakeSSHEnvironment(behavior: .openFails)
        defer { env.cleanUp() }

        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        let ready = try await transport.ensureMasterReady()

        // A failed open with no live master must report not-ready so the controller
        // can log/degrade rather than silently assume a clean mirror. The single
        // fallback probe also fails (no master), so the result is `false`.
        #expect(!ready)
    }

    @Test func cancellationDuringOpenAborts() async throws {
        let env = try FakeSSHEnvironment(behavior: .opensSlowly)
        defer { env.cleanUp() }

        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        // A v2VmCall timeout cancels the task mid-open; the gate must abort with
        // CancellationError instead of hanging or silently returning a result.
        let task = Task { try await transport.ensureMasterReady() }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    // MARK: - Fake ssh harness

    /// A throwaway `ssh` replacement plus the on-disk state it reads/writes.
    ///
    /// The script distinguishes the two invocations the gate makes purely from argv:
    /// `-O check` (readiness probe) versus everything else (the master-open `true`).
    /// It records each call to a log file and tracks "master up" with a sentinel
    /// file, so the test can assert call counts and ordering deterministically — no
    /// real network, no real `ssh`.
    private struct FakeSSHEnvironment {
        enum Behavior: Equatable {
            /// Cold: the first non-check run opens the master and exits 0.
            case opensOnFirstRun
            /// Warm: the master is already up before the first check.
            case alreadyRunning
            /// Broken: the open exits non-zero and the master never comes up.
            case openFails
            /// Slow: the open blocks (so a test can cancel mid-open) before opening.
            case opensSlowly
        }

        let root: URL
        let executablePath: String
        private let statePath: String
        private let logPath: String

        init(behavior: Behavior) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("remote-tmux-master-ready-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            statePath = root.appendingPathComponent("master-up").path
            logPath = root.appendingPathComponent("calls.log").path

            if behavior == .alreadyRunning {
                FileManager.default.createFile(atPath: statePath, contents: Data())
            }

            // `-O check` (probe): succeed iff the sentinel exists.
            // Anything else is the `true` open; its body depends on the behavior.
            let openBody: String
            switch behavior {
            case .opensOnFirstRun:
                openBody = ": > \"$STATE\"\nexit 0"
            case .alreadyRunning:
                // Never reached (warm check short-circuits), but keep it well-formed.
                openBody = ": > \"$STATE\"\nexit 0"
            case .openFails:
                openBody = "exit 1"
            case .opensSlowly:
                // Background the sleep and `wait`, so a SIGTERM (terminate on cancel)
                // interrupts `wait` and exits promptly instead of blocking ~5s.
                openBody = "trap 'exit 143' TERM\nsleep 5 &\nwait\n: > \"$STATE\"\nexit 0"
            }

            let script = """
            #!/bin/sh
            STATE='\(statePath)'
            LOG='\(logPath)'
            is_check=0
            prev=''
            for arg in "$@"; do
                if [ "$prev" = "-O" ] && [ "$arg" = "check" ]; then is_check=1; fi
                prev="$arg"
            done
            if [ "$is_check" = "1" ]; then
                printf 'check\\n' >> "$LOG"
                if [ -e "$STATE" ]; then exit 0; else exit 255; fi
            fi
            printf 'open\\n' >> "$LOG"
            \(openBody)
            """
            let scriptURL = root.appendingPathComponent("ssh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            executablePath = scriptURL.path
        }

        private func lines() -> [String] {
            guard let contents = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
            return contents.split(separator: "\n").map(String.init)
        }

        func openCount() -> Int { lines().filter { $0 == "open" }.count }
        func checkCount() -> Int { lines().filter { $0 == "check" }.count }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
