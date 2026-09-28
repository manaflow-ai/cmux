import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct TerminalSSHSessionDetectorProcessSnapshotTests {
    @Test("A TTY's foreground process group is read from the kernel with its members' names")
    func processSnapshotsFindTheForegroundProcessGroup() throws {
        var controller: Int32 = -1
        var follower: Int32 = -1
        var nameBuffer = [CChar](repeating: 0, count: 128)
        try #require(openpty(&controller, &follower, &nameBuffer, nil, nil) == 0)
        defer { close(controller) }
        let ttyPath = String(cString: nameBuffer)
        // The child opens the TTY after setsid so it becomes the controlling terminal.
        close(follower)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, ttyPath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)

        let arguments = ["/bin/sleep", "30"].map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        var pid: pid_t = 0
        try #require(posix_spawn(&pid, "/bin/sleep", &fileActions, &attributes, arguments, environ) == 0)
        defer {
            kill(pid, SIGKILL)
            waitpid(pid, nil, 0)
        }

        let ttyName = (ttyPath as NSString).lastPathComponent
        var snapshot: TerminalSSHSessionDetector.ProcessSnapshot?
        let deadline = Date().addingTimeInterval(10)
        // posix_spawn returns before the child has exec'd and opened its TTY.
        while Date() < deadline {
            snapshot = TerminalSSHSessionDetector.processSnapshots(inProcessGroup: pid, ttyName: ttyName)
                .first { $0.pid == pid && $0.executableName == "sleep" }
            if snapshot != nil { break }
            usleep(20_000)
        }

        let found = try #require(snapshot)
        #expect(found.tty == ttyName)
        #expect(found.pgid == pid)
        #expect(found.tpgid == pid)
        // A TTY that does not exist matches no member of the group.
        #expect(TerminalSSHSessionDetector.processSnapshots(inProcessGroup: pid, ttyName: "ttys-cmux-missing").isEmpty)
        #expect(TerminalSSHSessionDetector.detect(foregroundProcessGroup: pid, ttyName: ttyName) == nil)
    }

    @Test("An empty process group has no processes")
    func processSnapshotsForMissingProcessGroupAreEmpty() {
        #expect(TerminalSSHSessionDetector.processSnapshots(inProcessGroup: 0, ttyName: "ttys000").isEmpty)
    }
}
