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
        let job = try ForegroundJob(executable: "/bin/sleep", arguments: ["30"], leaderName: "sleep")
        defer { job.stop() }

        let leader = try #require(job.leader)
        #expect(leader.tty == job.ttyName)
        #expect(leader.pgid == leader.pid)
        #expect(leader.tpgid == leader.pid)
        // A TTY that does not exist matches no member of the group.
        #expect(TerminalSSHSessionDetector.processSnapshots(inProcessGroup: leader.pid, ttyName: "ttys-cmux-missing").isEmpty)
        // A readable group with no ssh member is a confident "no", not an unknown.
        #expect(TerminalSSHSessionDetector.foregroundJobHasRemoteShell(processGroupID: leader.pid, ttyName: job.ttyName) == false)
    }

    @Test("A foreground ssh job is still sent to SSH detection")
    func foregroundSSHJobIsARemoteShell() throws {
        // ProxyCommand keeps ssh running in the foreground without network access.
        let job = try ForegroundJob(
            executable: "/usr/bin/ssh",
            arguments: ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ProxyCommand=/bin/sleep 30", "cmux-test-host"],
            leaderName: "ssh"
        )
        defer { job.stop() }

        let leader = try #require(job.leader)
        #expect(TerminalSSHSessionDetector.foregroundJobHasRemoteShell(processGroupID: leader.pid, ttyName: job.ttyName) == true)
    }

    @Test("An empty process group has no processes")
    func processSnapshotsForMissingProcessGroupAreEmpty() {
        #expect(TerminalSSHSessionDetector.processSnapshots(inProcessGroup: 0, ttyName: "ttys000").isEmpty)
    }

    @Test("A group that cannot be read is unknown rather than local")
    func unreadableForegroundGroupIsUnknown() {
        // Nothing is learned about the job here, so the answer has to be nil.
        // A false would send the dropped path into a possibly remote shell as
        // a local path, which is the failure this distinction exists to stop.
        #expect(TerminalSSHSessionDetector.foregroundJobHasRemoteShell(processGroupID: 0, ttyName: "ttys000") == nil)
        #expect(TerminalSSHSessionDetector.foregroundJobHasRemoteShell(processGroupID: 1, ttyName: "") == nil)
        #expect(
            TerminalSSHSessionDetector.foregroundJobHasRemoteShell(
                processGroupID: 1,
                ttyName: "ttys-cmux-missing"
            ) == nil
        )
    }

    /// Runs a command as the foreground job of a new PTY through script(1),
    /// like a shell job in a terminal pane.
    private struct ForegroundJob {
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
}
