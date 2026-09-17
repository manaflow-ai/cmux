import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/12805.
///
/// Codex keeps a kernel `flock` on its thread writer lock for the life of the
/// process and treats the pty-close SIGHUP as a graceful-only shutdown, so an
/// agent could outlive cmux and still hold the lock when the relaunched app
/// ran `codex resume`. Quit must terminate the agents cmux spawned and wait for
/// their exact process generations to exit before it replies to AppKit.
///
/// Each test spawns a real agent stand-in on its own pty (so it has a
/// controlling TTY and the cmux scope environment that the termination path
/// validates), which takes a real `flock` and ignores SIGHUP.
@Suite("Agent quit termination", .serialized)
struct AgentQuitTerminationCoordinatorTests {
    @Test("Quit termination releases a writer lock held by an agent that ignores SIGHUP")
    func terminationReleasesLockHeldBySighupIgnoringAgent() async throws {
        let fixture = try AgentLockHolderFixture.spawn(ignoresSIGTERM: false)
        defer { fixture.cleanup() }

        #expect(!fixture.lockIsAcquirable(), "the fixture must hold the lock before quit termination runs")
        #expect(fixture.stillHoldsLockAfterSIGHUP())

        let outcome = await AgentQuitTerminationCoordinator(
            gracePeriod: .seconds(3),
            postKillExitPeriod: .seconds(2)
        ).terminateAndWait(scopes: [try fixture.scope()])

        #expect(outcome.exitedPanels == 1, Comment(rawValue: "\(outcome)"))
        #expect(outcome.rejectedPanels == 0, Comment(rawValue: "\(outcome)"))
        #expect(outcome.survivingPanels == 0, Comment(rawValue: "\(outcome)"))
        #expect(fixture.lockIsAcquirable(), "the agent must have released its writer lock before the coordinator returned")
        #expect(!fixture.agentIsAlive())
    }

    @Test("Quit termination escalates to SIGKILL when the agent ignores SIGTERM too")
    func terminationEscalatesToSigkill() async throws {
        let fixture = try AgentLockHolderFixture.spawn(ignoresSIGTERM: true)
        defer { fixture.cleanup() }

        #expect(!fixture.lockIsAcquirable())

        let outcome = await AgentQuitTerminationCoordinator(
            gracePeriod: .milliseconds(750),
            postKillExitPeriod: .seconds(3)
        ).terminateAndWait(scopes: [try fixture.scope()])

        #expect(outcome.exitedPanels == 1, Comment(rawValue: "\(outcome)"))
        #expect(outcome.survivingPanels == 0, Comment(rawValue: "\(outcome)"))
        #expect(fixture.lockIsAcquirable(), "SIGKILL must have released the kernel lock")
        #expect(!fixture.agentIsAlive())
    }

    @Test("A stale process generation is never signalled")
    func staleGenerationIsNeverSignalled() async throws {
        let fixture = try AgentLockHolderFixture.spawn(ignoresSIGTERM: false)
        defer { fixture.cleanup() }

        let outcome = await AgentQuitTerminationCoordinator(
            gracePeriod: .milliseconds(250),
            postKillExitPeriod: .milliseconds(250)
        ).terminateAndWait(scopes: [try fixture.scope(staleGeneration: true)])

        #expect(outcome.rejectedPanels == 1, Comment(rawValue: "\(outcome)"))
        #expect(outcome.exitedPanels == 0, Comment(rawValue: "\(outcome)"))
        #expect(fixture.agentIsAlive(), "a PID whose recorded generation does not match must be left alone")
        #expect(!fixture.lockIsAcquirable())
    }

    @Test("The quit deadline never re-saves the snapshot after agents were terminated")
    func agentTerminationPhaseTerminatesWithoutResave() {
        #expect(
            AppDelegate.terminateCleanupDeadlineDisposition(
                phase: .agentTermination,
                hasOwnedRuntimeCleanup: false
            ) == .terminateWithSavedSnapshot
        )
        #expect(
            AppDelegate.terminateCleanupDeadlineDisposition(
                phase: .agentTermination,
                hasOwnedRuntimeCleanup: true
            ) == .terminateWithSavedSnapshot
        )
        #expect(
            AppDelegate.terminateCleanupDeadlineDisposition(
                phase: .freshSnapshot,
                hasOwnedRuntimeCleanup: true
            ) == .persistCachedSnapshotAndTerminate
        )
    }
}

/// A real child process on its own pty that holds a `flock` and ignores SIGHUP,
/// the way Codex's embedded app-server keeps its thread writer lock through a
/// pty hangup.
private struct AgentLockHolderFixture {
    let workspaceID: UUID
    let panelID: UUID
    let launcherPID: pid_t
    let agentPID: pid_t
    let lockPath: String
    let root: URL

    static func spawn(ignoresSIGTERM: Bool) throws -> AgentLockHolderFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quit-termination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lockPath = root.appendingPathComponent("thread.lock").path
        let pidPath = root.appendingPathComponent("agent.pid").path
        let workspaceID = UUID()
        let panelID = UUID()

        // The parent keeps the pty master open and reaps the child; the child is
        // the "agent": a session leader with a controlling TTY, holding the lock.
        let script = """
        import fcntl, os, pty, signal, sys, time
        lock_path, pid_path, ignore_term = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
        pid, fd = pty.fork()
        if pid == 0:
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            if ignore_term:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
            lock = open(lock_path, 'a+')
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            with open(pid_path + '.tmp', 'w') as f:
                f.write(str(os.getpid()))
            os.rename(pid_path + '.tmp', pid_path)
            while True:
                signal.pause()
        else:
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        """
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_WORKSPACE_ID"] = workspaceID.uuidString
        environment["CMUX_SURFACE_ID"] = panelID.uuidString
        let launcherPID = try spawnProcess(
            executablePath: "/usr/bin/python3",
            arguments: ["/usr/bin/python3", "-c", script, lockPath, pidPath, ignoresSIGTERM ? "1" : "0"],
            environment: environment
        )

        let deadline = Date().addingTimeInterval(20)
        var agentPID: pid_t = 0
        while Date() < deadline {
            if let raw = try? String(contentsOfFile: pidPath, encoding: .utf8),
               let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0 {
                agentPID = pid
                break
            }
            var status: Int32 = 0
            if waitpid(launcherPID, &status, WNOHANG) == launcherPID {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ECHILD),
                    userInfo: [NSLocalizedDescriptionKey: "agent fixture launcher exited early: \(status)"]
                )
            }
            usleep(20_000)
        }
        guard agentPID > 0 else {
            kill(launcherPID, SIGKILL)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ETIMEDOUT),
                userInfo: [NSLocalizedDescriptionKey: "agent fixture did not report its PID"]
            )
        }
        return AgentLockHolderFixture(
            workspaceID: workspaceID,
            panelID: panelID,
            launcherPID: launcherPID,
            agentPID: agentPID,
            lockPath: lockPath,
            root: root
        )
    }

    func scope(staleGeneration: Bool = false) throws -> AgentHibernationController.ProcessTerminationScope {
        let identity = try #require(AgentPIDProcessIdentity(pid: agentPID))
        let recorded = staleGeneration
            ? AgentPIDProcessIdentity(
                pid: identity.pid,
                startSeconds: identity.startSeconds &+ 1,
                startMicroseconds: identity.startMicroseconds
            )
            : identity
        return AgentHibernationController.ProcessTerminationScope(
            key: AgentHibernationPanelKey(workspaceId: workspaceID, panelId: panelID),
            processIDs: [Int(agentPID)],
            processIdentities: [Int(agentPID): recorded]
        )
    }

    /// True when a fresh descriptor can take the exclusive lock, i.e. no other
    /// process holds it. `flock` is per open file description, so this probe
    /// observes the agent's lock from inside the test process.
    func lockIsAcquirable() -> Bool {
        let fd = open(lockPath, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    func stillHoldsLockAfterSIGHUP() -> Bool {
        guard kill(agentPID, SIGHUP) == 0 else { return false }
        usleep(150_000)
        return agentIsAlive() && !lockIsAcquirable()
    }

    func agentIsAlive() -> Bool {
        AgentPIDProcessIdentity(pid: agentPID) != nil
    }

    func cleanup() {
        kill(agentPID, SIGKILL)
        kill(launcherPID, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(launcherPID, &status, 0)
        try? FileManager.default.removeItem(at: root)
    }

    private static func spawnProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> pid_t {
        var processID: pid_t = 0
        var argumentPointers = arguments.map { strdup($0) }
        argumentPointers.append(nil)
        var environmentPointers = environment.map { strdup("\($0.key)=\($0.value)") }
        environmentPointers.append(nil)
        defer {
            for pointer in argumentPointers where pointer != nil { free(pointer) }
            for pointer in environmentPointers where pointer != nil { free(pointer) }
        }
        let spawnStatus = executablePath.withCString { executablePointer in
            argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
                environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &processID,
                        executablePointer,
                        nil,
                        nil,
                        argumentBuffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                }
            }
        }
        guard spawnStatus == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(spawnStatus))
        }
        return processID
    }
}
