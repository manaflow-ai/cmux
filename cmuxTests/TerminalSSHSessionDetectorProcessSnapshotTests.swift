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
        let job = try SSHDetectionForegroundJob(executable: "/bin/sleep", arguments: ["30"], leaderName: "sleep")
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
        let job = try SSHDetectionForegroundJob(
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
}
