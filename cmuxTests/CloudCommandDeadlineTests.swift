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

@Suite struct CloudCommandDeadlineTests {
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
        } catch CloudMachineLink.LinkError.timedOut {
            #expect(!cancel)
        }
        #expect(kill(pids[0], 0) == -1 && errno == ESRCH, "the directly owned child must be reaped")
        if let descendantPID = pids.dropFirst().first, returned {
            // Grandchildren are reaped by launchd; they must already have exited.
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let bytes = proc_pidinfo(descendantPID, PROC_PIDTBSDINFO, 0, &info, size)
            #expect(bytes == 0 || info.pbi_status == 5, "a pipe-holding descendant survived cleanup")
        }
    }
}
