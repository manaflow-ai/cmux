import Foundation
import CmuxRemoteWorkspace
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
/// single connection can't lose the creation race), then confirms with one
/// authoritative `ssh -O check`. The open's exit code is NOT trusted: under
/// `ControlMaster=auto` ssh can fall back to a non-multiplexed direct connection and
/// still exit 0 without a live shared master, so only the `-O check` proves the
/// burst can ride a live master.
///
/// The OpenSSH creation race itself isn't hermetically reproducible (it needs a
/// real multi-session host), so these tests lock in the *mechanism* that prevents
/// it: a fake `ssh` that records its invocations and tracks a master-up sentinel,
/// asserting the gate opens the master once when cold, is idempotent when warm, and
/// — crucially — reports not-ready when the open succeeds but no master is actually
/// up (the non-multiplexed-fallback hole). The single-flight coalescing of
/// concurrent callers is an actor-reentrancy property verified by review rather than
/// a (necessarily timing-dependent) unit test.
@Suite struct RemoteTmuxMasterReadinessTests {

    @Test func coldMasterIsOpenedOnceThenConfirmedReady() async throws {
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
        // Readiness is confirmed by an authoritative `ssh -O check` AFTER the open,
        // not assumed from the open's exit code: one initial warm-path probe plus
        // one post-open confirmation = two checks.
        #expect(env.checkCount() == 2)
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

    @Test func openSucceedingWithoutLiveMasterReportsNotReady() async throws {
        // The regression for the non-multiplexed-fallback hole: `run(["true"])`
        // exits 0 (ssh fell back to a direct connection) but no shared master is
        // accepting clients. Trusting the open's exit code here would report ready
        // and fire the attach burst into the cold-master race; the post-open
        // `ssh -O check` must catch it and report not-ready instead.
        let env = try FakeSSHEnvironment(behavior: .openSucceedsButMasterStaysDown)
        defer { env.cleanUp() }

        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        let ready = try await transport.ensureMasterReady()

        #expect(!ready)
        // The open ran (and "succeeded"), but the authoritative post-open check
        // still ran and is what determined the not-ready result.
        #expect(env.openCount() == 1)
        #expect(env.checkCount() == 2)
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
            /// Cold: the first non-check run opens the master (sentinel) and exits 0.
            case opensOnFirstRun
            /// Warm: the master is already up before the first check.
            case alreadyRunning
            /// Fallback hole: the open exits 0 (non-multiplexed direct connection)
            /// but the shared master never comes up, so `-O check` keeps failing.
            case openSucceedsButMasterStaysDown
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
            case .opensOnFirstRun, .alreadyRunning:
                // `.alreadyRunning` never reaches the open (warm check short-circuits),
                // but keep a well-formed success body that brings the master up.
                openBody = ": > \"$STATE\"\nexit 0"
            case .openSucceedsButMasterStaysDown:
                // Exit 0 like a non-multiplexed fallback, but never create the
                // sentinel — the shared master stays down, so `-O check` keeps failing.
                openBody = "exit 0"
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
