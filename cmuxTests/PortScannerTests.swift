import CmuxCore
import CmuxFoundation
import Darwin
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Port scanner owner-scoped completeness")
struct PortScannerOwnerScopedCompletenessTests {
    @Test("An unrelated incomplete PID does not pin a known listener port")
    func unrelatedIncompletePIDDoesNotPinListener() {
        let workspaceID = UUID()
        let listener = AgentPIDProcessIdentity(pid: 101, startSeconds: 10, startMicroseconds: 0)
        let unrelated = AgentPIDProcessIdentity(pid: 102, startSeconds: 11, startMicroseconds: 0)
        let scanner = PortScanner(
            processIdentityProvider: { pid in
                pid == listener.pid ? listener : nil
            },
            processPresenceProvider: { _ in .present }
        )
        let lsofScan = PortLsofScanResult(
            values: [:],
            globallyComplete: true,
            incompletePIDs: [Int(unrelated.pid)]
        )

        let completeness = scanner.missingPortCompletenessByKey(
            previousOwnersByKey: [workspaceID: [4200: [listener]]],
            observedOwnersByKey: [:],
            currentProcessIdentitiesByKey: [workspaceID: [listener]],
            processScopeCompletenessByKey: [workspaceID: .incomplete],
            scannedKeys: [workspaceID],
            lsofScan: lsofScan,
            inspectedPIDs: [Int(listener.pid)]
        )

        #expect(completeness[workspaceID]?[4200] == .complete)
    }

    @Test("An unreadable live owner keeps its missing port incomplete")
    func unreadableLiveOwnerRemainsIncomplete() {
        let workspaceID = UUID()
        let listener = AgentPIDProcessIdentity(pid: 101, startSeconds: 10, startMicroseconds: 0)
        let scanner = PortScanner(
            processIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in .present }
        )
        let lsofScan = PortLsofScanResult(
            values: [:],
            globallyComplete: true,
            incompletePIDs: []
        )

        let completeness = scanner.missingPortCompletenessByKey(
            previousOwnersByKey: [workspaceID: [4200: [listener]]],
            observedOwnersByKey: [:],
            currentProcessIdentitiesByKey: [:],
            processScopeCompletenessByKey: [workspaceID: .incomplete],
            scannedKeys: [workspaceID],
            lsofScan: lsofScan,
            inspectedPIDs: [Int(listener.pid)]
        )

        #expect(completeness[workspaceID]?[4200] == .incomplete)
    }
}

@Suite("Port scanner ownership-scope evidence")
struct PortScannerOwnershipScopeEvidenceTests {
    @Test("A live owner dropped by an incomplete graph does not retire its port")
    func incompleteOwnershipGraphRetainsLiveOwnerPort() {
        let workspaceID = UUID()
        let listener = AgentPIDProcessIdentity(pid: 101, startSeconds: 10, startMicroseconds: 0)
        let scanner = PortScanner(
            processIdentityProvider: { _ in listener },
            processPresenceProvider: { _ in .present }
        )
        let lsofScan = PortLsofScanResult(
            values: [Int(listener.pid): [4200]],
            globallyComplete: true,
            incompletePIDs: []
        )

        let completeness = scanner.missingPortCompletenessByKey(
            previousOwnersByKey: [workspaceID: [4200: [listener]]],
            observedOwnersByKey: [:],
            currentProcessIdentitiesByKey: [:],
            processScopeCompletenessByKey: [workspaceID: .incomplete],
            scannedKeys: [workspaceID],
            lsofScan: lsofScan,
            inspectedPIDs: [Int(listener.pid)]
        )

        #expect(completeness[workspaceID]?[4200] == .incomplete)
    }

    @Test("A live owner absent from a complete graph is authoritative absence")
    func completeOwnershipGraphRetiresDroppedOwnerPort() {
        let workspaceID = UUID()
        let listener = AgentPIDProcessIdentity(pid: 101, startSeconds: 10, startMicroseconds: 0)
        let scanner = PortScanner(
            processIdentityProvider: { _ in listener },
            processPresenceProvider: { _ in .present }
        )
        let lsofScan = PortLsofScanResult(
            values: [Int(listener.pid): [4200]],
            globallyComplete: true,
            incompletePIDs: []
        )

        let completeness = scanner.missingPortCompletenessByKey(
            previousOwnersByKey: [workspaceID: [4200: [listener]]],
            observedOwnersByKey: [:],
            currentProcessIdentitiesByKey: [:],
            processScopeCompletenessByKey: [workspaceID: .complete],
            scannedKeys: [workspaceID],
            lsofScan: lsofScan,
            inspectedPIDs: [Int(listener.pid)]
        )

        #expect(completeness[workspaceID]?[4200] == .complete)
    }

    @Test("Unrelated incomplete lsof evidence does not pin a dropped owner")
    func unrelatedIncompleteLsofDoesNotPinDroppedOwner() {
        let workspaceID = UUID()
        let listener = AgentPIDProcessIdentity(pid: 101, startSeconds: 10, startMicroseconds: 0)
        let scanner = PortScanner(
            processIdentityProvider: { _ in listener },
            processPresenceProvider: { _ in .present }
        )
        let lsofScan = PortLsofScanResult(
            values: [Int(listener.pid): [4200]],
            globallyComplete: false,
            incompletePIDs: [999]
        )

        let completeness = scanner.missingPortCompletenessByKey(
            previousOwnersByKey: [workspaceID: [4200: [listener]]],
            observedOwnersByKey: [:],
            currentProcessIdentitiesByKey: [:],
            processScopeCompletenessByKey: [workspaceID: .complete],
            scannedKeys: [workspaceID],
            lsofScan: lsofScan,
            inspectedPIDs: [Int(listener.pid)]
        )

        #expect(completeness[workspaceID]?[4200] == .complete)
    }
}

@Suite("Port scanner process capture")
struct PortScannerProcessCaptureTests {
    @Test("Malformed ps rows preserve valid mappings but make the scan incomplete")
    func malformedPSRowsAreIncomplete() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "123 ttys001\nmalformed\n456 ttys002 extra\n",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scan = await PortScanner(commandRunner: runner).runPS(ttyList: "ttys001,ttys002")

        #expect(scan.values == [123: "ttys001"])
        #expect(scan.completeness == .incomplete)
    }

    @Test("Malformed lsof rows are incomplete only for their owning PID")
    func malformedLsofRowsArePIDScoped() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "p123\nf3\nn*:4200\nnmalformed\np456\nf3\nn*:4300\n",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scan = await PortScanner(
            commandRunner: runner,
            processIdentityProvider: {
                AgentPIDProcessIdentity(pid: $0, startSeconds: 1, startMicroseconds: 0)
            }
        ).runLsof(pidsCsv: "123,456")

        #expect(scan.values == [123: [4200], 456: [4300]])
        #expect(scan.completeness(for: [123]) == .incomplete)
        #expect(scan.completeness(for: [456]) == .complete)
    }

    @Test("A clean lsof field stream is complete")
    func cleanLsofRowsAreComplete() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "p123\nf3\nn*:4200\n",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scan = await PortScanner(
            commandRunner: runner,
            processIdentityProvider: {
                AgentPIDProcessIdentity(pid: $0, startSeconds: 1, startMicroseconds: 0)
            }
        ).runLsof(pidsCsv: "123")

        #expect(scan.values == [123: [4200]])
        #expect(scan.completeness == .complete)
    }

    @Test("lsof diagnostics preserve valid ports but make the scan incomplete")
    func lsofDiagnosticsAreIncomplete() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "p123\nf3\nn*:4200\n",
            stderr: "lsof: permission denied\n",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scan = await PortScanner(commandRunner: runner).runLsof(pidsCsv: "123")

        #expect(scan.values == [123: [4200]])
        #expect(scan.completeness == .incomplete)
    }

    @Test("Filesystem warnings do not poison lsof TCP evidence")
    func filesystemWarningsAreSuppressedForLsofTCPScan() async {
        let pid = 123
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(pid),
            startSeconds: 1,
            startMicroseconds: 0
        )
        let runner = PortLifecycleCommandRunner(
            ttyName: "ttys001",
            sessionLeaderPID: 1,
            pid: pid,
            port: 4200
        )
        let scan = await PortScanner(
            commandRunner: runner,
            processIdentityProvider: { $0 == identity.pid ? identity : nil },
            processPresenceProvider: { $0 == identity.pid ? .present : .absent }
        ).runLsof(pidsCsv: String(pid))
        let arguments = await runner.lastLsofArguments

        #expect(scan.values == [pid: [4200]])
        #expect(scan.completeness(for: [pid]) == .complete)
        #expect(arguments?.contains("-w") == true)
    }

    @Test("A confirmed absent PID is safe negative lsof evidence")
    func absentPIDIsCompleteNegativeEvidence() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "p100\nf3\nn*:4200\n",
            stderr: "",
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        ))
        let liveIdentity = AgentPIDProcessIdentity(
            pid: 100,
            startSeconds: 1,
            startMicroseconds: 0
        )
        let scan = await PortScanner(
            commandRunner: runner,
            processIdentityProvider: { $0 == liveIdentity.pid ? liveIdentity : nil },
            processPresenceProvider: { $0 == liveIdentity.pid ? .present : .absent }
        ).runLsof(pidsCsv: "100,200")

        #expect(scan.values == [100: [4200]])
        #expect(scan.completeness(for: [100]) == .complete)
        #expect(scan.completeness(for: [200]) == .complete)
    }

    @Test("A process owned by another user still has a readable birth identity")
    func otherUsersProcessHasReadableIdentity() throws {
        // launchd is root-owned on every macOS system, so `proc_pidinfo`
        // refuses it for an unprivileged caller — the same refusal that hides
        // the root `login` process heading every terminal's process group.
        try #require(geteuid() != 0, "the cross-user identity test must run unprivileged")
        var legacyInfo = proc_bsdinfo()
        let expectedLegacySize = MemoryLayout<proc_bsdinfo>.stride
        let legacySize = proc_pidinfo(
            1,
            PROC_PIDTBSDINFO,
            0,
            &legacyInfo,
            Int32(expectedLegacySize)
        )
        #expect(legacySize != expectedLegacySize, "proc_pidinfo unexpectedly read launchd")

        let identity = try #require(AgentPIDProcessIdentity(pid: 1))

        #expect(identity.pid == 1)
        #expect(identity.startSeconds > 0)
        #expect(AgentPIDProcessIdentity(pid: getpid())?.pid == getpid())
        #expect(AgentPIDProcessIdentity(pid: 999_999) == nil)
    }

    @Test("An exited but unreaped process has no readable identity")
    func zombieProcessHasNoReadableIdentity() throws {
        // `sysctl` still describes a zombie, and reports its original birth
        // timestamp, so a caller comparing identities would decide the dead
        // process is the one it recorded and treat the agent as running.
        var pid: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { arguments.compactMap { $0 }.forEach { free($0) } }
        try #require(posix_spawn(&pid, "/usr/bin/true", nil, nil, &arguments, environ) == 0)
        defer {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, Self.processStatus(pid: pid) != SZOMB {
            usleep(10_000)
        }

        try #require(Self.processStatus(pid: pid) == SZOMB, "the child never became a zombie")
        #expect(AgentPIDProcessIdentity(pid: pid) == nil)
    }

    @Test("A zombie on a panel's TTY does not withhold negative port evidence")
    func zombieProcessIsAuthoritativeAbsence() async throws {
        // Rejecting zombies as identities is only half the story: a zombie is
        // still signalable, so presence read it as live and `runLsof` filed it
        // as a PID whose ports might have gone unseen. That is the same
        // incompleteness that froze every panel behind the root `login`, and a
        // zombie can hold no socket at all.
        var pid: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { arguments.compactMap { $0 }.forEach { free($0) } }
        try #require(posix_spawn(&pid, "/usr/bin/true", nil, nil, &arguments, environ) == 0)
        defer {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, Self.processStatus(pid: pid) != SZOMB {
            usleep(10_000)
        }
        try #require(Self.processStatus(pid: pid) == SZOMB, "the child never became a zombie")

        let panel = PortScanner.PanelKey(workspaceId: UUID(), panelId: UUID())
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "",
            stderr: "",
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        ))
        let lsofScan = await PortScanner(commandRunner: runner).runLsof(pidsCsv: String(pid))
        let completeness = PortScanner.panelCompletenessByKey(
            panelTTYs: [panel: "ttys001"],
            pidToTTY: [Int(pid): "ttys001"],
            psCompleteness: .complete,
            lsofScan: lsofScan
        )

        #expect(PIDPresence.current(pid: pid) == .absent)
        #expect(lsofScan.completeness(for: [Int(pid)]) == .complete)
        #expect(completeness[panel] == .complete)
    }

    /// The raw `p_stat` the process table reports, or `nil` when the process is
    /// gone entirely.
    private static func processStatus(pid: pid_t) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              info.kp_proc.p_pid == pid else {
            return nil
        }
        return Int32(info.kp_proc.p_stat)
    }

    @Test("A panel hosting a root-owned process can still retire its ports")
    func panelWithRootOwnedProcessStaysComplete() async {
        let panel = PortScanner.PanelKey(workspaceId: UUID(), panelId: UUID())
        let rootOwnedPID = 1
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "",
            stderr: "",
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        ))
        let lsofScan = await PortScanner(commandRunner: runner)
            .runLsof(pidsCsv: String(rootOwnedPID))

        let completeness = PortScanner.panelCompletenessByKey(
            panelTTYs: [panel: "ttys001"],
            pidToTTY: [rootOwnedPID: "ttys001"],
            psCompleteness: .complete,
            lsofScan: lsofScan
        )

        #expect(lsofScan.completeness(for: [rootOwnedPID]) == .complete)
        #expect(completeness[panel] == .complete)
    }

    @Test("Panel lsof completeness is scoped to PIDs on that panel's TTY")
    func panelLsofCompletenessIsTTYScoped() {
        let workspaceID = UUID()
        let healthyPanel = PortScanner.PanelKey(workspaceId: workspaceID, panelId: UUID())
        let failedPanel = PortScanner.PanelKey(workspaceId: workspaceID, panelId: UUID())
        let lsofScan = PortLsofScanResult(
            values: [100: [4200]],
            globallyComplete: true,
            incompletePIDs: [200]
        )

        let completeness = PortScanner.panelCompletenessByKey(
            panelTTYs: [healthyPanel: "ttys001", failedPanel: "ttys002"],
            pidToTTY: [100: "ttys001", 200: "ttys002"],
            psCompleteness: .complete,
            lsofScan: lsofScan
        )

        #expect(completeness[healthyPanel] == .complete)
        #expect(completeness[failedPanel] == .incomplete)
    }

    @Test("A panel with no PIDs needs only an authoritative process scan")
    func noPIDPanelCompletenessUsesProcessScan() {
        let panel = PortScanner.PanelKey(workspaceId: UUID(), panelId: UUID())

        let complete = PortScanner.panelCompletenessByKey(
            panelTTYs: [panel: "ttys001"],
            pidToTTY: [:],
            psCompleteness: .complete,
            lsofScan: nil
        )
        let incomplete = PortScanner.panelCompletenessByKey(
            panelTTYs: [panel: "ttys001"],
            pidToTTY: [:],
            psCompleteness: .incomplete,
            lsofScan: nil
        )

        #expect(complete[panel] == .complete)
        #expect(incomplete[panel] == .incomplete)
    }

    @Test("A vanished TTY device does not discard the surviving panels' processes")
    func missingTTYDeviceDoesNotDiscardSurvivingPanels() async {
        let runner = ScriptedCommandRunner(results: [
            CommandResult(
                stdout: "",
                stderr: "ps: /dev/ttys011: No such file or directory\n",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            ),
            CommandResult(
                stdout: "123 ttys001\n",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        ])

        let scan = await PortScanner(commandRunner: runner).runPS(ttyList: "ttys001,ttys011")
        let arguments = await runner.recordedArguments

        #expect(scan.values == [123: "ttys001"])
        #expect(scan.completeness == .complete)
        #expect(arguments == [
            ["-t", "ttys001,ttys011", "-o", "pid=,tty="],
            ["-t", "ttys001", "-o", "pid=,tty="]
        ])
    }

    @Test("Every TTY device vanishing is authoritative emptiness, not a failed scan")
    func allTTYDevicesMissingIsCompleteAndEmpty() async {
        let runner = ScriptedCommandRunner(results: [
            CommandResult(
                stdout: "",
                stderr: """
                ps: /dev/ttys011: No such file or directory
                ps: /dev/ttys091: No such file or directory

                """,
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            )
        ])

        let scan = await PortScanner(commandRunner: runner).runPS(ttyList: "ttys011,ttys091")
        let arguments = await runner.recordedArguments

        #expect(scan.values.isEmpty)
        #expect(scan.completeness == .complete)
        #expect(arguments == [["-t", "ttys011,ttys091", "-o", "pid=,tty="]])
    }

    @Test("A diagnostic that names no requested TTY stays incomplete without retrying")
    func unrecognizedPSDiagnosticsStayIncomplete() async {
        let runner = ScriptedCommandRunner(results: [
            CommandResult(
                stdout: "123 ttys001\n",
                stderr: "ps: unable to obtain kernel process table\n",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            )
        ])

        let scan = await PortScanner(commandRunner: runner).runPS(ttyList: "ttys001,ttys011")
        let arguments = await runner.recordedArguments

        #expect(scan.values == [123: "ttys001"])
        #expect(scan.completeness == .incomplete)
        #expect(arguments == [["-t", "ttys001,ttys011", "-o", "pid=,tty="]])
    }

    @Test("A diagnostic that names a requested TTY with another errno stays incomplete")
    func nonMissingDeviceDiagnosticStaysIncomplete() async {
        let runner = ScriptedCommandRunner(results: [
            CommandResult(
                stdout: "123 ttys001\n",
                stderr: "ps: /dev/ttys011: Permission denied\n",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            )
        ])

        let scan = await PortScanner(commandRunner: runner).runPS(ttyList: "ttys001,ttys011")
        let arguments = await runner.recordedArguments

        // A device that exists but cannot be read is missing evidence, not
        // absence: dropping it would retire live ports.
        #expect(scan.values == [123: "ttys001"])
        #expect(scan.completeness == .incomplete)
        #expect(arguments == [["-t", "ttys001,ttys011", "-o", "pid=,tty="]])
    }

    @Test("A vanished TTY alongside an unreadable one keeps the scan incomplete")
    func mixedVanishedAndUnreadableDiagnosticsStayIncomplete() async {
        let runner = ScriptedCommandRunner(results: [
            CommandResult(
                stdout: "",
                stderr: """
                ps: /dev/ttys011: No such file or directory
                ps: /dev/ttys001: Permission denied

                """,
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            ),
            CommandResult(
                stdout: "",
                stderr: "ps: /dev/ttys001: Permission denied\n",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            )
        ])

        let scan = await PortScanner(commandRunner: runner).runPS(ttyList: "ttys001,ttys011")
        let arguments = await runner.recordedArguments

        // The vanished terminal must not launder the unreadable one into
        // completeness: only the unreadable terminal is re-queried, and its
        // persisting diagnostic leaves the scan incomplete.
        #expect(scan.values.isEmpty)
        #expect(scan.completeness == .incomplete)
        #expect(arguments == [
            ["-t", "ttys001,ttys011", "-o", "pid=,tty="],
            ["-t", "ttys001", "-o", "pid=,tty="]
        ])
    }

    @Test("The two-device diagnostic form still identifies the vanished TTY")
    func combinedDeviceDiagnosticIdentifiesVanishedTTY() async {
        // `ps` stats both /dev/tty<name> and /dev/<name> for a name that does
        // not already begin with "tty", and names both in one diagnostic.
        let runner = ScriptedCommandRunner(results: [
            CommandResult(
                stdout: "",
                stderr: "ps: /dev/ttyremote7 and /dev/remote7: No such file or directory\n",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            ),
            CommandResult(
                stdout: "123 ttys001\n",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        ])

        let scan = await PortScanner(commandRunner: runner).runPS(ttyList: "ttys001,remote7")
        let arguments = await runner.recordedArguments

        #expect(scan.values == [123: "ttys001"])
        #expect(scan.completeness == .complete)
        #expect(arguments == [
            ["-t", "ttys001,remote7", "-o", "pid=,tty="],
            ["-t", "ttys001", "-o", "pid=,tty="]
        ])
    }

    @Test("A TTY registered by full device path is still recognized as vanished")
    func fullDevicePathTTYIsRecognizedAsVanished() async {
        // `registerTTY` stores whatever the shell reported, and `$(tty)` yields
        // the full device path.
        let runner = ScriptedCommandRunner(results: [
            CommandResult(
                stdout: "",
                stderr: "ps: /dev/ttys011: No such file or directory\n",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            ),
            CommandResult(
                stdout: "123 ttys001\n",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        ])

        let scan = await PortScanner(commandRunner: runner).runPS(ttyList: "ttys001,/dev/ttys011")
        let arguments = await runner.recordedArguments

        #expect(scan.values == [123: "ttys001"])
        #expect(scan.completeness == .complete)
        #expect(arguments == [
            ["-t", "ttys001,/dev/ttys011", "-o", "pid=,tty="],
            ["-t", "ttys001", "-o", "pid=,tty="]
        ])
    }

    @Test("The last TTY vanishing on the final attempt is still authoritative emptiness")
    func lastTTYVanishingOnFinalAttemptIsComplete() async {
        let runner = ScriptedCommandRunner(results: [
            CommandResult(
                stdout: "",
                stderr: "ps: /dev/ttys011: No such file or directory\n",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            ),
            CommandResult(
                stdout: "",
                stderr: "ps: /dev/ttys012: No such file or directory\n",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            ),
            CommandResult(
                stdout: "",
                stderr: "ps: /dev/ttys013: No such file or directory\n",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            )
        ])

        let scan = await PortScanner(commandRunner: runner)
            .runPS(ttyList: "ttys011,ttys012,ttys013")

        // Whether the last pty closes on the first or the final attempt, no
        // process can be attached to a freed device, so the empty result is
        // evidence rather than a failed scan.
        #expect(scan.values.isEmpty)
        #expect(scan.completeness == .complete)
    }

    @Test("A TTY that stays unscannable after the retry budget stays incomplete")
    func repeatedlyVanishingTTYsExhaustTheRetryBudget() async {
        let runner = ScriptedCommandRunner(results: [
            CommandResult(
                stdout: "",
                stderr: "ps: /dev/ttys011: No such file or directory\n",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            ),
            CommandResult(
                stdout: "",
                stderr: "ps: /dev/ttys012: No such file or directory\n",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            ),
            CommandResult(
                stdout: "",
                stderr: "ps: /dev/ttys013: No such file or directory\n",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            )
        ])

        let scan = await PortScanner(commandRunner: runner)
            .runPS(ttyList: "ttys001,ttys011,ttys012,ttys013")
        let arguments = await runner.recordedArguments

        #expect(scan.values.isEmpty)
        #expect(scan.completeness == .incomplete)
        #expect(arguments == [
            ["-t", "ttys001,ttys011,ttys012,ttys013", "-o", "pid=,tty="],
            ["-t", "ttys001,ttys012,ttys013", "-o", "pid=,tty="],
            ["-t", "ttys001,ttys013", "-o", "pid=,tty="]
        ])
    }

    @Test("Process scan timeout is bounded and incomplete")
    func processScanTimeoutIsIncomplete() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: nil,
            stderr: nil,
            exitStatus: nil,
            timedOut: true,
            executionError: nil
        ))
        let scan = await PortScanner(commandRunner: runner).runPS(ttyList: "ttys001")
        let timeout = await runner.lastTimeout

        #expect(scan.values.isEmpty)
        #expect(scan.completeness == .incomplete)
        #expect(timeout == PortScanner.processScanTimeout)
    }
}

@Suite("Agent process identity validation")
struct AgentProcessIdentityValidationTests {
    @Test("Nested roots visit and own each descendant once per workspace")
    func nestedRootsHaveBoundedWorkspaceOwnership() async {
        let workspaceID = UUID()
        let firstIdentity = AgentPIDProcessIdentity(pid: 100, startSeconds: 10, startMicroseconds: 0)
        let secondIdentity = AgentPIDProcessIdentity(pid: 101, startSeconds: 20, startMicroseconds: 0)
        let firstRoot = AgentPortRootIdentity(pid: 100, processIdentity: firstIdentity)
        let secondRoot = AgentPortRootIdentity(pid: 101, processIdentity: secondIdentity)
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "100 1\n101 100\n102 101\n103 102\n",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scanner = PortScanner(
            commandRunner: runner,
            processIdentityProvider: { pid in
                switch pid {
                case firstIdentity.pid: firstIdentity
                case secondIdentity.pid: secondIdentity
                default: nil
                }
            }
        )

        let scan = await scanner.expandAgentProcessTree(
            agentRootsByWorkspace: [workspaceID: [firstRoot, secondRoot]]
        )

        #expect(scan.values == [100: [workspaceID], 101: [workspaceID], 102: [workspaceID], 103: [workspaceID]])
        #expect(scan.completenessByWorkspace[workspaceID] == .complete)
    }

    @Test("A matching birth identity is retained for process-tree expansion")
    func matchingIdentityIsAccepted() {
        let workspaceID = UUID()
        let identity = AgentPIDProcessIdentity(
            pid: 100,
            startSeconds: 10,
            startMicroseconds: 20
        )
        let root = AgentPortRootIdentity(pid: 100, processIdentity: identity)
        let scanner = PortScanner(processIdentityProvider: { pid in
            pid == identity.pid ? identity : nil
        })

        let validation = scanner.validateAgentRoots([workspaceID: [root]])

        #expect(validation.values == [workspaceID: [root]])
        #expect(validation.completenessByWorkspace[workspaceID] == .complete)
    }

    @Test("Roots recycled or unavailable after process capture retain no descendants")
    func postCaptureInvalidRootsAreRejectedBeforeTraversal() async {
        let workspaceID = UUID()
        let recorded = AgentPIDProcessIdentity(pid: 100, startSeconds: 10, startMicroseconds: 20)
        let recycled = AgentPIDProcessIdentity(pid: 100, startSeconds: 11, startMicroseconds: 0)
        let root = AgentPortRootIdentity(pid: 100, processIdentity: recorded)
        for postCaptureIdentity in [recycled, nil] as [AgentPIDProcessIdentity?] {
            // Serializes the async runner's identity flip with synchronous provider reads.
            let identity = OSAllocatedUnfairLock(initialState: Optional(recorded))
            let runner = StubCommandRunner(
                result: CommandResult(
                    stdout: "100 1\n101 100\n",
                    stderr: "",
                    exitStatus: 0,
                    timedOut: false,
                    executionError: nil
                ),
                onRun: { identity.withLock { $0 = postCaptureIdentity } }
            )
            let scanner = PortScanner(
                commandRunner: runner,
                processIdentityProvider: { _ in identity.withLock { $0 } },
                processPresenceProvider: { _ in .present }
            )

            let scan = await scanner.expandAgentProcessTree(agentRootsByWorkspace: [workspaceID: [root]])

            #expect(scan.values.isEmpty)
            #expect(scan.completenessByWorkspace[workspaceID] == (postCaptureIdentity == nil ? .incomplete : .complete))
        }
    }

    @Test("An initially unavailable root skips the process scan with incomplete evidence")
    func initiallyUnavailableRootSkipsProcessScan() async {
        let workspaceID = UUID()
        let identity = AgentPIDProcessIdentity(pid: 100, startSeconds: 10, startMicroseconds: 20)
        let root = AgentPortRootIdentity(pid: 100, processIdentity: identity)
        // Serializes the async runner callback with the synchronous assertion read.
        let didRun = OSAllocatedUnfairLock(initialState: false)
        let runner = StubCommandRunner(
            result: CommandResult(
                stdout: "100 1\n",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            ),
            onRun: { didRun.withLock { $0 = true } }
        )
        let scanner = PortScanner(
            commandRunner: runner,
            processIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in .present }
        )

        let scan = await scanner.expandAgentProcessTree(agentRootsByWorkspace: [workspaceID: [root]])

        #expect(scan.values.isEmpty)
        #expect(scan.completenessByWorkspace[workspaceID] == .incomplete)
        #expect(didRun.withLock { $0 } == false)
    }

    @Test("One unavailable root does not widen incompleteness to another workspace")
    func rootCompletenessIsWorkspaceScoped() {
        let healthyWorkspaceID = UUID()
        let unavailableWorkspaceID = UUID()
        let healthyIdentity = AgentPIDProcessIdentity(pid: 100, startSeconds: 10, startMicroseconds: 0)
        let unavailableIdentity = AgentPIDProcessIdentity(pid: 200, startSeconds: 20, startMicroseconds: 0)
        let healthyRoot = AgentPortRootIdentity(pid: 100, processIdentity: healthyIdentity)
        let unavailableRoot = AgentPortRootIdentity(pid: 200, processIdentity: unavailableIdentity)
        let scanner = PortScanner(
            processIdentityProvider: { pid in
                pid == healthyIdentity.pid ? healthyIdentity : nil
            },
            processPresenceProvider: { _ in .present }
        )

        let validation = scanner.validateAgentRoots([
            healthyWorkspaceID: [healthyRoot],
            unavailableWorkspaceID: [unavailableRoot]
        ])

        #expect(validation.completenessByWorkspace[healthyWorkspaceID] == .complete)
        #expect(validation.completenessByWorkspace[unavailableWorkspaceID] == .incomplete)
    }

    @Test("lsof incompleteness is scoped to workspaces that own the failed PID")
    func lsofCompletenessIsPIDScoped() {
        let scan = PortLsofScanResult(
            values: [100: [4200]],
            globallyComplete: true,
            incompletePIDs: [200]
        )

        #expect(scan.completeness(for: [100]) == .complete)
        #expect(scan.completeness(for: [200]) == .incomplete)
        #expect(scan.completeness(for: [100, 200]) == .incomplete)
    }
}

@Suite("Port scan coordination")
struct PortScanCoordinationTests {
    @Test("Panel scans stay single-flight and coalesce one pending pass")
    func panelScansAreBoundedAndCoalesced() {
        var coordination = PortScanCoordination()

        let firstScan = coordination.beginPanelScan()
        #expect(firstScan)
        let firstPendingScan = coordination.beginPanelScan()
        #expect(firstPendingScan == false)
        let coalescedPendingScan = coordination.beginPanelScan()
        #expect(coalescedPendingScan == false)
        let shouldRunPendingScan = coordination.finishPanelScan()
        #expect(shouldRunPendingScan)
        let pendingScan = coordination.beginPanelScan()
        #expect(pendingScan)
        let isFinished = coordination.finishPanelScan()
        #expect(isFinished == false)
    }

    @Test("Agent scans merge pending workspace inputs behind one in-flight pass")
    func agentScansAreBoundedAndMerged() throws {
        var coordination = PortScanCoordination()
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()
        let first = AgentPortScanRequest(
            workspaceIds: [firstWorkspace],
            rootInput: AgentPortScanRootInput(
                rootsByWorkspace: [firstWorkspace: [AgentPortRootIdentity(pid: 100, processIdentity: nil)]]
            ),
            agentRevisions: [firstWorkspace: 1],
            requestID: coordination.makeRequestID()
        )
        let newer = AgentPortScanRequest(
            workspaceIds: [firstWorkspace, secondWorkspace],
            rootInput: AgentPortScanRootInput(rootsByWorkspace: [
                firstWorkspace: [AgentPortRootIdentity(pid: 101, processIdentity: nil)],
                secondWorkspace: [AgentPortRootIdentity(pid: 200, processIdentity: nil)]
            ]),
            agentRevisions: [firstWorkspace: 2, secondWorkspace: 1],
            requestID: coordination.makeRequestID()
        )
        let latest = AgentPortScanRequest(
            workspaceIds: [secondWorkspace],
            rootInput: AgentPortScanRootInput(
                rootsByWorkspace: [secondWorkspace: [AgentPortRootIdentity(pid: 201, processIdentity: nil)]]
            ),
            agentRevisions: [secondWorkspace: 2],
            requestID: coordination.makeRequestID()
        )

        let firstScan = coordination.enqueueAgentScan(first)
        #expect(firstScan == first)
        let coalescedScan = coordination.enqueueAgentScan(newer)
        #expect(coalescedScan == nil)
        let mergedScan = coordination.enqueueAgentScan(latest)
        #expect(mergedScan == nil)
        let finishedScan = coordination.finishAgentScan()
        let pending = try #require(finishedScan)
        let pendingRoots = pending.rootInput.rootsByWorkspace
        #expect(pending.workspaceIds == [firstWorkspace, secondWorkspace])
        #expect(pendingRoots[firstWorkspace]?.map(\.pid) == [101])
        #expect(pendingRoots[secondWorkspace]?.map(\.pid) == [201])
        #expect(pending.agentRevisions == [firstWorkspace: 2, secondWorkspace: 2])
        #expect(pending.requestID == latest.requestID)

        let nextScan = coordination.enqueueAgentScan(first)
        #expect(nextScan == nil)
        let nextPending = coordination.finishAgentScan()
        #expect(nextPending?.requestID == first.requestID)
    }

    @Test("Older asynchronous results are rejected after a newer result applies")
    func staleResultsAreRejected() {
        var coordination = PortScanCoordination()
        let workspaceID = UUID()
        let older = coordination.makeRequestID()
        let newer = coordination.makeRequestID()

        let newerPanelResult = coordination.shouldApplyPanelResult(requestID: newer)
        #expect(newerPanelResult)
        let olderPanelResult = coordination.shouldApplyPanelResult(requestID: older)
        #expect(olderPanelResult == false)
        let newerAgentWorkspaces = coordination.newAgentWorkspaces(
            [workspaceID],
            eligibleWorkspaceIds: [workspaceID],
            requestID: newer
        )
        #expect(newerAgentWorkspaces == [workspaceID])
        let olderAgentWorkspaces = coordination.newAgentWorkspaces(
            [workspaceID],
            eligibleWorkspaceIds: [workspaceID],
            requestID: older
        )
        #expect(olderAgentWorkspaces.isEmpty)
        #expect(coordination.isLatestAgentResult(workspaceId: workspaceID, requestID: newer))
    }

    @Test("Agent ordering only retains eligible lifecycle workspaces")
    func agentOrderingOnlyRetainsEligibleWorkspaces() {
        var coordination = PortScanCoordination()
        let panelOnlyWorkspaceID = UUID()
        let forcedClearWorkspaceID = UUID()
        let requestID = coordination.makeRequestID()

        let agentWorkspaces = coordination.newAgentWorkspaces(
            [panelOnlyWorkspaceID, forcedClearWorkspaceID],
            eligibleWorkspaceIds: [forcedClearWorkspaceID],
            requestID: requestID
        )

        #expect(agentWorkspaces == [forcedClearWorkspaceID])
        #expect(coordination.isLatestAgentResult(workspaceId: panelOnlyWorkspaceID, requestID: requestID) == false)
        #expect(coordination.isLatestAgentResult(workspaceId: forcedClearWorkspaceID, requestID: requestID))

        coordination.removeAgentWorkspaces([forcedClearWorkspaceID])

        #expect(coordination.isLatestAgentResult(workspaceId: forcedClearWorkspaceID, requestID: requestID) == false)
    }

}

@Suite("Process termination gate")
struct ProcessTerminationGateTests {
    @Test("A prelaunch termination request is deferred until launch")
    func prelaunchTerminationRequestIsDeferredUntilLaunch() {
        var gate = ProcessTerminationGate()

        let shouldTerminateBeforeLaunch = gate.requestTermination()
        #expect(shouldTerminateBeforeLaunch == false)
        let shouldTerminateAfterLaunch = gate.markLaunched()
        #expect(shouldTerminateAfterLaunch)
        gate.markFinished()
        let shouldTerminateAfterFinish = gate.requestTermination()
        #expect(shouldTerminateAfterFinish == false)
    }

    @Test("A finished prelaunch process ignores deferred termination")
    func finishedPrelaunchProcessIgnoresDeferredTermination() {
        var gate = ProcessTerminationGate()

        let shouldTerminateBeforeLaunch = gate.requestTermination()
        #expect(shouldTerminateBeforeLaunch == false)
        gate.markFinished()
        let shouldTerminateAfterFinish = gate.markLaunched()
        #expect(shouldTerminateAfterFinish == false)
    }
}

/// Replays exactly one scripted result per invocation so unexpected retries
/// fail instead of silently reusing stale evidence.
private actor ScriptedCommandRunner: CommandRunning {
    private let results: [CommandResult]
    private(set) var recordedArguments: [[String]] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        recordedArguments.append(arguments)
        let index = recordedArguments.count - 1
        guard results.indices.contains(index) else {
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: false,
                executionError: "unexpected scripted command invocation \(recordedArguments.count)"
            )
        }
        return results[index]
    }
}

@Suite("Port scanner lifecycle")
struct PortScannerLifecycleTests {
    @Test("Unregister cancels a pending coalesce and burst generation")
    func unregisterCancelsPendingBurst() async {
        let runner = ScriptedCommandRunner(results: [])
        let scanner = PortScanner(commandRunner: runner)
        let workspaceID = UUID()
        let panelID = UUID()
        await MainActor.run {
            scanner.registerTTY(workspaceId: workspaceID, panelId: panelID, ttyName: "ttys999")
        }
        scanner.kick(workspaceId: workspaceID, panelId: panelID)
        await MainActor.run {
            scanner.unregisterPanel(workspaceId: workspaceID, panelId: panelID)
        }
        try? await Task.sleep(for: .milliseconds(800))
        let calls = await runner.recordedArguments
        #expect(calls.isEmpty)
    }
}

@Suite("Port scanner retirement end to end")
struct PortScannerPortRetirementTests {
    /// Drives the whole scanner — TTY registration, kick, coalesce, burst,
    /// reconcile, publish — so a break anywhere in that chain surfaces even
    /// when every individual stage still passes its own test.
    @Test("A published port retires despite unrelated lsof filesystem warnings")
    func publishedPortIsRetiredAfterProcessStopsListening() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyName = "ttys901"
        // A real terminal's process group is the root-owned session leader plus
        // the user's own processes, so the panel is scanned with launchd
        // standing in for `login` and the test process standing in for the
        // server. Identity and presence stay on the real providers: substituting
        // them is what makes an end-to-end port test pass over a broken scanner.
        let sessionLeaderPID = 1
        let listenerPID = Int(getpid())
        let listeningPort = 4321
        let runner = PortLifecycleCommandRunner(
            ttyName: ttyName,
            sessionLeaderPID: sessionLeaderPID,
            pid: listenerPID,
            port: listeningPort
        )
        let listenerIdentity = try #require(AgentPIDProcessIdentity(pid: pid_t(listenerPID)))
        let sessionIdentity = TerminalTTYSessionIdentity(processIdentity: listenerIdentity)
        let scanner = PortScanner(
            commandRunner: runner,
            ttySessionIdentityProvider: { _ in sessionIdentity }
        )
        let publishedPorts = OSAllocatedUnfairLock(initialState: [[Int]]())

        await MainActor.run {
            scanner.onPortsUpdated = { publishedWorkspaceId, publishedPanelId, ports in
                guard publishedWorkspaceId == workspaceId, publishedPanelId == panelId else { return }
                publishedPorts.withLock { $0.append(ports) }
            }
            scanner.registerTTY(workspaceId: workspaceId, panelId: panelId, ttyName: ttyName)
        }
        scanner.kick(workspaceId: workspaceId, panelId: panelId)

        let didPublishListeningPort = await Self.waitForPublication(
            in: publishedPorts,
            matching: { $0 == [listeningPort] },
            onKick: { scanner.kick(workspaceId: workspaceId, panelId: panelId) }
        )
        try #require(didPublishListeningPort, "the listening port was never published")

        // Only publications recorded after the port stops being held count as
        // retirement; an earlier empty publication is registration noise.
        let publicationsBeforeStop = publishedPorts.withLock { $0.count }
        await runner.stopListening()

        let didRetirePort = await Self.waitForPublication(
            in: publishedPorts,
            after: publicationsBeforeStop,
            matching: \.isEmpty,
            onKick: { scanner.kick(workspaceId: workspaceId, panelId: panelId) }
        )

        #expect(didRetirePort, "the port was never retired after its process stopped listening")
    }

    /// A kick can arrive near the end of a burst that began for an earlier
    /// shell event. The kick still needs enough later scans to supply the three
    /// complete misses required by `PortScanSnapshotReconciler`.
    @Test("A single late-burst kick still retires a stopped listener")
    func lateBurstKickRetiresStoppedListener() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyName = "ttys902"
        let listenerPID = Int(getpid())
        let listeningPort = 4322
        let runner = PortLifecycleCommandRunner(
            ttyName: ttyName,
            sessionLeaderPID: 1,
            pid: listenerPID,
            port: listeningPort
        )
        let listenerIdentity = try #require(AgentPIDProcessIdentity(pid: pid_t(listenerPID)))
        let sessionIdentity = TerminalTTYSessionIdentity(processIdentity: listenerIdentity)
        let scanner = PortScanner(
            commandRunner: runner,
            ttySessionIdentityProvider: { _ in sessionIdentity }
        )
        let publishedPorts = OSAllocatedUnfairLock(initialState: [[Int]]())

        await MainActor.run {
            scanner.onPortsUpdated = { publishedWorkspaceId, publishedPanelId, ports in
                guard publishedWorkspaceId == workspaceId, publishedPanelId == panelId else { return }
                publishedPorts.withLock { $0.append(ports) }
            }
            scanner.registerTTY(workspaceId: workspaceId, panelId: panelId, ttyName: ttyName)
        }
        scanner.kick(workspaceId: workspaceId, panelId: panelId)

        let didPublishListeningPort = await Self.waitForPublication(
            in: publishedPorts,
            matching: { $0 == [listeningPort] },
            onKick: {}
        )
        try #require(didPublishListeningPort, "the listening port was never published")

        // The fifth scan is at 7.5 seconds in the six-scan burst. Stopping here
        // leaves only the 10-second scan in the original burst, so clearing the
        // kick at that scan strands the port after only one complete miss.
        let reachedFifthScan = await runner.waitForLsofInvocation(5)
        try #require(reachedFifthScan, "the scanner did not reach the fifth burst scan")
        let publicationsBeforeStop = publishedPorts.withLock { $0.count }
        await runner.stopListening()
        scanner.kick(workspaceId: workspaceId, panelId: panelId)

        let didRetirePort = await Self.waitForPublication(
            in: publishedPorts,
            after: publicationsBeforeStop,
            matching: \.isEmpty,
            onKick: {},
            timeout: .seconds(12)
        )

        #expect(didRetirePort, "a late-burst kick did not schedule enough complete misses")
    }

    /// `/bin/ps` accepts a full device path in `-t`, but reports the matching
    /// process's TTY without `/dev/`. The scanner must still attribute the
    /// listener to the panel that registered the full path.
    @Test("A live full-path TTY still attributes its listener")
    func liveFullPathTTYAttributesListener() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let registeredTTYName = "/dev/ttys903"
        let processTTYName = "ttys903"
        let listenerPID = Int(getpid())
        let listeningPort = 4323
        let runner = PortLifecycleCommandRunner(
            ttyName: registeredTTYName,
            processTTYName: processTTYName,
            sessionLeaderPID: 1,
            pid: listenerPID,
            port: listeningPort
        )
        let listenerIdentity = try #require(AgentPIDProcessIdentity(pid: pid_t(listenerPID)))
        let sessionIdentity = TerminalTTYSessionIdentity(processIdentity: listenerIdentity)
        let scanner = PortScanner(
            commandRunner: runner,
            ttySessionIdentityProvider: { _ in sessionIdentity }
        )
        let publishedPorts = OSAllocatedUnfairLock(initialState: [[Int]]())

        await MainActor.run {
            scanner.onPortsUpdated = { publishedWorkspaceId, publishedPanelId, ports in
                guard publishedWorkspaceId == workspaceId, publishedPanelId == panelId else { return }
                publishedPorts.withLock { $0.append(ports) }
            }
            scanner.registerTTY(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyName: registeredTTYName
            )
        }
        scanner.kick(workspaceId: workspaceId, panelId: panelId)

        let didPublishListeningPort = await Self.waitForPublication(
            in: publishedPorts,
            matching: { $0 == [listeningPort] },
            onKick: { scanner.kick(workspaceId: workspaceId, panelId: panelId) },
            timeout: .seconds(6)
        )

        #expect(didPublishListeningPort, "the full-path TTY never received its listener")
    }

    /// Polls rather than sleeping a fixed interval, since the scan burst runs
    /// on real timers whose spacing shifts under load.
    ///
    /// The interval must stay above the scanner's 200ms kick coalesce window:
    /// each kick reschedules that timer, so polling faster than it starves the
    /// burst and no scan ever runs.
    private static func waitForPublication(
        in publishedPorts: OSAllocatedUnfairLock<[[Int]]>,
        after startIndex: Int = 0,
        matching predicate: @Sendable ([Int]) -> Bool,
        onKick: @Sendable () -> Void,
        timeout: Duration = .seconds(20)
    ) async -> Bool {
        func isSatisfied() -> Bool {
            publishedPorts.withLock { $0.dropFirst(startIndex).contains(where: predicate) }
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isSatisfied() { return true }
            onKick()
            // Cancellation makes the sleep throw immediately; without this the
            // poll would spin until the wall-clock deadline.
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                break
            }
        }
        return isSatisfied()
    }
}

/// Reports one listening port on one TTY until `stopListening()`, after which
/// the process is still alive but owns no sockets.
private actor PortLifecycleCommandRunner: CommandRunning {
    private let ttyName: String
    private let processTTYName: String
    private let sessionLeaderPID: Int
    private let pid: Int
    private let port: Int
    private var isListening = true
    private(set) var lastLsofArguments: [String]?
    private var lsofInvocationCount = 0

    private static let filesystemWarning = """
    lsof: WARNING: can't stat() smbfs file system /Volumes/.timemachine/example
          Output information may be incomplete.
          assuming "dev=deadbeef" from mount table

    """

    init(
        ttyName: String,
        processTTYName: String? = nil,
        sessionLeaderPID: Int,
        pid: Int,
        port: Int
    ) {
        self.ttyName = ttyName
        self.processTTYName = processTTYName ?? ttyName
        self.sessionLeaderPID = sessionLeaderPID
        self.pid = pid
        self.port = port
    }

    func stopListening() {
        isListening = false
    }

    func waitForLsofInvocation(_ target: Int, timeout: Duration = .seconds(15)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while lsofInvocationCount < target, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return lsofInvocationCount >= target
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        if executable.hasSuffix("ps") {
            if arguments.first == "-ax" {
                return Self.output("\(pid) 1\n")
            }
            // Honor the `-t` selector: a scan that asks about another terminal
            // must not be handed this panel's processes.
            let selectedTTYs = Self.selection(for: "-t", in: arguments)
            guard selectedTTYs.contains(ttyName) || selectedTTYs.contains(processTTYName) else {
                return Self.noSelectedFiles()
            }
            return Self.output("\(sessionLeaderPID) \(processTTYName)\n\(pid) \(processTTYName)\n")
        }
        lsofInvocationCount += 1
        lastLsofArguments = arguments
        // `lsof -w` suppresses filesystem warnings. They are unrelated to a
        // PID-scoped TCP socket query, but any stderr currently makes the
        // scanner globally incomplete and prevents stale ports from aging out.
        let stderr = arguments.contains("-w") ? "" : Self.filesystemWarning
        guard isListening, Self.selection(for: "-p", in: arguments).contains(String(pid)) else {
            return Self.noSelectedFiles(stderr: stderr)
        }
        return Self.output("p\(pid)\nf3\nn127.0.0.1:\(port)\n", stderr: stderr)
    }

    /// The comma-separated values the command was asked to select on.
    private static func selection(for flag: String, in arguments: [String]) -> Set<String> {
        guard let flagIndex = arguments.firstIndex(of: flag) else { return [] }
        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex else { return [] }
        return Set(arguments[valueIndex].split(separator: ",").map(String.init))
    }

    private static func output(_ stdout: String, stderr: String = "") -> CommandResult {
        CommandResult(
            stdout: stdout,
            stderr: stderr,
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }

    /// Both `ps` and `lsof` exit 1 with no output when a valid selector matches
    /// nothing.
    private static func noSelectedFiles(stderr: String = "") -> CommandResult {
        CommandResult(
            stdout: "",
            stderr: stderr,
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        )
    }
}

private actor StubCommandRunner: CommandRunning {
    let result: CommandResult
    let onRun: (@Sendable () -> Void)?
    private(set) var lastTimeout: TimeInterval?

    init(result: CommandResult, onRun: (@Sendable () -> Void)? = nil) {
        self.result = result
        self.onRun = onRun
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        lastTimeout = timeout
        onRun?()
        return result
    }
}
