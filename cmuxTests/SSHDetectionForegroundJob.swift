import Darwin
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Runs a command as the foreground job of a new PTY through script(1),
/// like a shell job in a terminal pane.
struct SSHDetectionForegroundJob {
    let script: Process
    let ttyName: String
    let leader: TerminalSSHSessionDetector.ProcessSnapshot?

    init(executable: String, arguments: [String], leaderName: String) throws {
        script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        script.arguments = ["-q", "/dev/null", executable] + arguments
        script.standardInput = FileHandle.nullDevice
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice
        try script.run()

        var ttyName = ""
        var leader: TerminalSSHSessionDetector.ProcessSnapshot?
        let deadline = Date().addingTimeInterval(10)
        // The child execs and acquires its TTY after script.run() returns.
        while leader == nil, Date() < deadline {
            if let child = Self.childWithControllingTTY(of: script.processIdentifier) {
                ttyName = child.ttyName
                leader = TerminalSSHSessionDetector
                    .processSnapshots(inProcessGroup: child.pid, ttyName: child.ttyName)
                    .first { $0.pid == child.pid && $0.executableName == leaderName }
            }
            if leader == nil { usleep(20_000) }
        }
        self.ttyName = ttyName
        self.leader = leader
    }

    /// script(1) owns and reaps its child, so stop only script; the child
    /// gets SIGHUP when the PTY closes. Signalling a stored PID could hit a
    /// reused PID after the child exits.
    func stop() {
        script.terminate()
        script.waitUntilExit()
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
