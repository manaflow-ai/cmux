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
        // script(1) gives its child a new PTY as the controlling terminal and
        // makes it the foreground process group, like a shell job in a pane.
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        script.arguments = ["-q", "/dev/null", "/bin/sleep", "30"]
        script.standardInput = FileHandle.nullDevice
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice
        try script.run()
        defer { script.terminate() }

        var child: (pid: Int32, ttyName: String)?
        var snapshot: TerminalSSHSessionDetector.ProcessSnapshot?
        let deadline = Date().addingTimeInterval(10)
        // The child execs sleep and acquires its TTY after script.run() returns.
        while snapshot == nil, Date() < deadline {
            child = Self.childWithControllingTTY(of: script.processIdentifier)
            if let child {
                snapshot = TerminalSSHSessionDetector
                    .processSnapshots(inProcessGroup: child.pid, ttyName: child.ttyName)
                    .first { $0.pid == child.pid && $0.executableName == "sleep" }
            }
            if snapshot == nil { usleep(20_000) }
        }
        defer { if let child { kill(child.pid, SIGKILL) } }

        let found = try #require(snapshot)
        let ttyName = try #require(child?.ttyName)
        #expect(found.tty == ttyName)
        #expect(found.pgid == found.pid)
        #expect(found.tpgid == found.pid)
        // A TTY that does not exist matches no member of the group.
        #expect(TerminalSSHSessionDetector.processSnapshots(inProcessGroup: found.pid, ttyName: "ttys-cmux-missing").isEmpty)
        #expect(TerminalSSHSessionDetector.detect(foregroundProcessGroup: found.pid, ttyName: ttyName) == nil)
    }

    @Test("An empty process group has no processes")
    func processSnapshotsForMissingProcessGroupAreEmpty() {
        #expect(TerminalSSHSessionDetector.processSnapshots(inProcessGroup: 0, ttyName: "ttys000").isEmpty)
    }

    private static func childWithControllingTTY(of parent: pid_t) -> (pid: Int32, ttyName: String)? {
        var children = [pid_t](repeating: 0, count: 8)
        let count = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        for pid in children.prefix(Int(max(count, 0))) where pid > 0 {
            var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
                  info.kp_eproc.e_tdev != -1,
                  let name = devname(info.kp_eproc.e_tdev, S_IFCHR) else {
                continue
            }
            return (pid, String(cString: name))
        }
        return nil
    }
}
