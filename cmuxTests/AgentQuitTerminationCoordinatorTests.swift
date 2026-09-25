import CmuxFoundation
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
        #expect(try fixture.stillHoldsLockAfterSIGHUP())

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
    let agentIdentity: AgentPIDProcessIdentity
    let acknowledgmentFD: Int32
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
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        var handedOff = false
        defer {
            close(descriptors[1])
            if !handedOff { close(descriptors[0]); try? FileManager.default.removeItem(at: root) }
        }
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        let workspaceID = UUID()
        let panelID = UUID()

        // The parent keeps the pty master open and reaps the child; the child is
        // the "agent": a session leader with a controlling TTY, holding the lock.
        let script = """
        import fcntl, os, pty, signal, sys
        lock_path, ack, ignore_term = sys.argv[1], int(sys.argv[2]), sys.argv[3] == '1'
        pid, fd = pty.fork()
        if pid == 0:
            signal.signal(signal.SIGHUP, lambda *_: os.write(ack, b'hup\\n'))
            if ignore_term:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
            lock = open(lock_path, 'a+')
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            os.write(ack, (str(os.getpid()) + '\\n').encode())
            while True:
                signal.pause()
        else:
            os.close(ack)
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
            arguments: ["/usr/bin/python3", "-c", script, lockPath, String(descriptors[1]), ignoresSIGTERM ? "1" : "0"],
            environment: environment
        )

        let agentPID: pid_t
        let identity: AgentPIDProcessIdentity
        do {
            agentPID = try #require(pid_t(try readEvent(from: descriptors[0])))
            identity = try #require(AgentPIDProcessIdentity(pid: agentPID))
        } catch {
            kill(launcherPID, SIGKILL)
            _ = waitpid(launcherPID, nil, 0)
            throw error
        }
        handedOff = true
        return AgentLockHolderFixture(
            agentIdentity: identity,
            acknowledgmentFD: descriptors[0],
            workspaceID: workspaceID,
            panelID: panelID,
            launcherPID: launcherPID,
            agentPID: agentPID,
            lockPath: lockPath,
            root: root
        )
    }

    func scope(staleGeneration: Bool = false) throws -> AgentHibernationController.ProcessTerminationScope {
        let identity = agentIdentity
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

    func stillHoldsLockAfterSIGHUP() throws -> Bool {
        guard kill(agentPID, SIGHUP) == 0 else { return false }
        guard try Self.readEvent(from: acknowledgmentFD) == "hup" else { return false }
        return agentIsAlive() && !lockIsAcquirable()
    }

    func agentIsAlive() -> Bool {
        AgentPIDProcessIdentity(pid: agentPID) == agentIdentity
    }

    func cleanup() {
        if AgentPIDProcessIdentity(pid: agentPID) == agentIdentity { kill(agentPID, SIGKILL) }
        close(acknowledgmentFD)
        kill(launcherPID, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(launcherPID, &status, 0)
        try? FileManager.default.removeItem(at: root)
    }

    /// Read the child's explicit readiness/signal acknowledgment, bounded by one deadline.
    private static func readEvent(from descriptor: Int32) throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var bytes: [UInt8] = []
        while bytes.count < 128 {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let milliseconds = remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000
            guard milliseconds > 0 else { throw POSIXError(.ETIMEDOUT) }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, Int32(milliseconds))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw POSIXError(.ETIMEDOUT) }
            var byte: UInt8 = 0
            guard read(descriptor, &byte, 1) == 1 else { throw POSIXError(.EPIPE) }
            if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        throw POSIXError(.EINVAL)
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
