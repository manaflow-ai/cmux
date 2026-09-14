import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#elseif canImport(CloudCommandFixture)
@testable import CloudCommandFixture
#endif

@Suite(.serialized, .timeLimit(.minutes(1))) struct CloudCommandDeadlineTests {
    @Test(arguments: [false, true])
    func termIgnoringCommandFinishes(cancel: Bool) async throws {
        try await checkFixture(descendant: false, cancel: cancel)
    }

    @Test(arguments: [false, true])
    func parentExitDoesNotDisablePipeDeadline(cancel: Bool) async throws {
        try await checkFixture(descendant: true, cancel: cancel)
    }

    @Test func normalExitPreservesOutputAndStatus() async throws {
        let link = CloudMachineLink(
            machineID: "fixture", clientURL: URL(fileURLWithPath: "/bin/sh"), paths: CloudTuiClientPaths()
        )
        let payload = Data(repeating: 0x61, count: 1_024)
        let data = try await link.run(arguments: ["-c", "cat; printf tail"], input: payload)
        #expect(data == payload + Data("tail".utf8))
        do {
            _ = try await link.run(arguments: ["-c", "printf stdout; printf stderr >&2; exit 7"])
            Issue.record("a nonzero child exit must fail")
        } catch CloudMachineLink.LinkError.exited(let status, let output) {
            #expect(status == 7)
            #expect(output == "stderr")
        }
    }

    @Test func drainsLargeConcurrentOutputWithoutChangingBytes() async throws {
        let link = CloudMachineLink(
            machineID: "fixture", clientURL: URL(fileURLWithPath: "/bin/sh"), paths: CloudTuiClientPaths()
        )
        let output = try await link.run(arguments: [
            "-c", "head -c 1048576 /dev/zero >&2 & head -c 1048576 /dev/zero; wait"
        ])
        #expect(output == Data(repeating: 0, count: 1_048_576))
    }

    @Test func rejectsExpiredDeadlineAndOversizedInputBeforeSpawn() async throws {
        let link = CloudMachineLink(
            machineID: "fixture", clientURL: URL(fileURLWithPath: "/does/not/exist"), paths: CloudTuiClientPaths()
        )
        await #expect(throws: CloudMachineLink.LinkError.self) {
            _ = try await link.run(arguments: [], timeout: .zero)
        }
        do {
            _ = try await link.run(arguments: [], input: Data(repeating: 0, count: 1_025))
            Issue.record("oversized input must be rejected before spawning")
        } catch CloudMachineLink.LinkError.inputTooLarge {}
    }

    @Test func expiryWinsWhenEOFArrivesBeforeTimerResumes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-command-wake-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = root.appendingPathComponent("exit-gate")
        try #require(mkfifo(gate.path, 0o600) == 0)
        let fd = open(gate.path, O_RDWR | O_NONBLOCK)
        try #require(fd >= 0)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let clock = CloudCommandDeadlineClock()
        let link = CloudMachineLink(
            machineID: "fixture", clientURL: URL(fileURLWithPath: "/bin/sh"),
            paths: CloudTuiClientPaths(home: root), commandClock: clock
        )
        let command = Task {
            try await link.run(arguments: ["-c", "read value < '\(gate.path)'; printf complete"], timeout: .seconds(30))
        }
        #expect(await clock.timerRegistered.result == true)
        clock.advanceWithoutWakingTimer(by: .seconds(600))
        try handle.write(contentsOf: Data("exit\n".utf8))
        do {
            _ = try await command.value
            Issue.record("EOF after the deadline cannot turn an expired command into success")
        } catch CloudMachineLink.LinkError.commandTimedOut {}
    }

    #if canImport(CloudCommandFixture)
    @Test func repeatedCommandsReleaseEveryCaptureDescriptor() async throws {
        let link = CloudMachineLink(
            machineID: "fixture", clientURL: URL(fileURLWithPath: "/bin/sh"), paths: CloudTuiClientPaths()
        )
        _ = try await link.run(arguments: ["-c", "printf warmup"])
        let before = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        for _ in 0..<24 {
            _ = try await link.run(arguments: ["-c", "printf normal; printf diagnostic >&2"])
        }
        let after = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        print("COMMAND_FD_PROOF beforeBytes=\(before) afterBytes=\(after) iterations=24")
        #expect(after <= before, "capture descriptors must be closed before each command returns")
    }

    @Test func appSuspensionDoesNotAcceptExpiredSuccessOnResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-command-stop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        try #require(mkfifo(ready.path, 0o600) == 0)
        let fd = open(ready.path, O_RDWR | O_NONBLOCK)
        try #require(fd >= 0)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var lines = CloudLinkPipe.lines(from: handle).makeAsyncIterator()
        let link = CloudMachineLink(
            machineID: "fixture", clientURL: URL(fileURLWithPath: "/bin/sh"), paths: CloudTuiClientPaths(home: root)
        )
        let started = ContinuousClock.now
        let active = SuspendingClock.now
        let command = Task {
            try await link.run(arguments: ["-c", "echo ready > '\(ready.path)'; sleep 0.1; printf complete"], timeout: .milliseconds(300))
        }
        #expect(await lines.next() == "ready")
        // Only the disposable standalone test executable is suspended. The helper
        // resumes it even if signalled; this test is excluded from app-host builds.
        let resume = Process()
        resume.executableURL = URL(fileURLWithPath: "/bin/sh")
        let parent = getpid()
        resume.arguments = ["-c", "trap 'kill -CONT \(parent)' EXIT; kill -STOP \(parent); sleep 0.6; kill -CONT \(parent)"]
        resume.standardInput = FileHandle.nullDevice
        resume.standardOutput = FileHandle.nullDevice
        resume.standardError = FileHandle.nullDevice
        let exited = CloudLinkFirstValue<Bool>()
        resume.terminationHandler = { _ in exited.resolve(true) }
        try resume.run()
        do {
            _ = try await command.value
            Issue.record("a child exit delivered on resume must still honor the elapsed deadline")
        } catch CloudMachineLink.LinkError.commandTimedOut {}
        #expect(await exited.result == true)
        print("COMMAND_SUSPEND_PROOF stopSeconds=0.6 continuous=\(started.duration(to: .now)) systemActive=\(active.duration(to: .now))")
    }
    #endif

    private func checkFixture(descendant: Bool, cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-command-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        try #require(mkfifo(ready.path, 0o600) == 0)
        let descriptor = open(ready.path, O_RDWR | O_NONBLOCK)
        try #require(descriptor >= 0)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var lines = CloudLinkPipe.lines(from: handle).makeAsyncIterator()
        let script = descendant
            ? "trap '' TERM; /bin/sleep 30 & echo \"$$ $!\" > '\(ready.path)'; exit 0"
            : "trap '' TERM; echo $$ > '\(ready.path)'; exec /bin/sleep 30"
        let link = CloudMachineLink(
            machineID: "fixture", clientURL: URL(fileURLWithPath: "/bin/sh"), paths: CloudTuiClientPaths(home: root)
        )
        let active = SuspendingClock.now
        let continuous = ContinuousClock.now
        let command = Task { try await link.run(arguments: ["-c", script], timeout: cancel ? .seconds(30) : .milliseconds(300)) }
        let line = try #require(await lines.next())
        let pids = line.split(separator: " ").compactMap { Int32($0) }
        try #require(pids.count == (descendant ? 2 : 1))
        // The watchdog is test containment, independent of the runner's task group.
        // Its wait is cancellable; old code cannot hang CI or leave a fixture alive.
        let finished = CloudLinkFirstValue<Bool>()
        let watcher = Task {
            _ = try? await command.value
            finished.resolve(true)
        }
        if cancel { command.cancel() }
        let returned = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await finished.result ?? false }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        let activeDuration = active.duration(to: .now)
        let continuousDuration = continuous.duration(to: .now)
        print("COMMAND_FIXTURE descendant=\(descendant) cancelled=\(cancel) returned=\(returned) active=\(activeDuration) continuous=\(continuousDuration)")
        if !returned {
            for pid in pids { _ = kill(pid, SIGKILL) }
        }
        await watcher.value
        #expect(returned, "runner remained blocked; active=\(activeDuration), continuous=\(continuousDuration)")
        #expect(activeDuration < .seconds(1), "deadline/cancellation plus cleanup must be bounded: \(activeDuration)")
        do {
            _ = try await command.value
            Issue.record("unfinished command or pipe drain must not be reported as success")
        } catch is CancellationError {
            #expect(cancel)
        } catch CloudMachineLink.LinkError.commandTimedOut {
            #expect(!cancel)
        }
        #expect(kill(pids[0], 0) == -1 && errno == ESRCH, "the directly owned child must be reaped")
        if let descendantPID = pids.dropFirst().first, returned {
            // Grandchildren are reaped by launchd; they must already have exited.
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let bytes = proc_pidinfo(descendantPID, PROC_PIDTBSDINFO, 0, &info, size)
            #expect(bytes == 0 || info.pbi_status == 5, "a pipe-holding descendant survived cleanup")
            if bytes != 0, info.pbi_status != 5 { _ = kill(descendantPID, SIGKILL) }
        }
    }
}
