import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Image paste in a plain `ssh` pane uploads to the host when cmux can read the
/// foreground ssh's command line (https://github.com/manaflow-ai/cmux/issues/22073).
///
/// OpenSSH keeps reading options after the destination, up to the first word of
/// the remote command: `ssh example-server -t my-tui` forces a terminal, and
/// `ssh example-server -p 2222 -l bob` connects to port 2222 as bob. Detection
/// stopped reading at the destination, so it rejected the first as a
/// non-interactive command and would have uploaded the second to port 22 as the
/// local user.
@Suite(.serialized)
struct SSHDetectionOptionsAfterDestinationTests {
    /// Keeps a real `/usr/bin/ssh` in the foreground without any network: it
    /// waits on this proxy for a server banner that never comes.
    private static let offlineSSH = ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ProxyCommand=/bin/sleep 30"]

    /// Runs the real ssh with `arguments` after the offline options, as the
    /// foreground job of its own terminal, and asks the detector about that terminal.
    private func detectRealSSH(_ arguments: [String]) throws -> DetectedSSHSession? {
        let job = try SSHDetectionForegroundJob(
            executable: "/usr/bin/ssh",
            arguments: Self.offlineSSH + arguments,
            leaderName: "ssh"
        )
        defer { job.stop() }
        _ = try #require(job.leader, "ssh never became the foreground job of its terminal")
        return TerminalSSHSessionDetector.detect(forTTY: job.ttyName)
    }

    @Test func aTTYForcedAfterTheDestinationIsAnUploadTarget() throws {
        let session = try detectRealSSH(["example-server", "-t", "python3", "/tmp/paste-receiver.py"])
        #expect(session?.destination == "example-server")
    }

    @Test func connectionOptionsAfterTheDestinationReachTheUploadTarget() throws {
        let session = try #require(try detectRealSSH(["example-server", "-p", "2222", "-l", "bob", "-t", "tmux"]))
        #expect(session.destination == "bob@example-server")
        #expect(session.port == 2222)
    }

    /// The same rules for every argv shape, without a process: what OpenSSH
    /// (`ssh -G`) reads from each, and whether a paste may upload to it.
    @Test(arguments: [
        // A forced terminal after the destination, in each spelling.
        (["ssh", "host", "-t", "my-tui"], true),
        (["ssh", "host", "-tt", "my-tui"], true),
        (["ssh", "host", "-o", "RequestTTY=force", "my-tui"], true),
        // Options after the remote command are the command's own.
        (["ssh", "host", "my-tui", "-t"], false),
        (["ssh", "host", "my-tui"], false),
        // `--` before the destination ends option parsing; after it, it starts the command.
        (["ssh", "--", "host", "-t"], false),
        (["ssh", "-t", "--", "host", "-t"], true),
        (["ssh", "host", "--", "-t"], false),
        (["ssh", "host", "--"], true),
        // A session with no shell, wherever the option is.
        (["ssh", "host", "-N"], false),
        (["ssh", "host", "-W", "other:22"], false),
        (["ssh", "host", "-o", "RequestTTY=no"], false),
        (["ssh", "host", "-T", "-t", "my-tui"], true),
        (["ssh", "host"], true),
        (["ssh", "host", "-P", "work"], true),
    ] as [([String], Bool)])
    func optionsAfterTheDestinationDecideWhetherPasteUploads(_ arguments: [String], _ uploads: Bool) {
        #expect((Self.detect(arguments) != nil) == uploads, "\(arguments)")
    }

    @Test func connectionSettingsAfterTheDestinationAreRead() throws {
        let session = try #require(Self.detect(["ssh", "-t", "host", "-p2222", "-i", "/keys/id", "-J", "jump", "tmux"]))
        #expect(session.port == 2222)
        #expect(session.identityFile == "/keys/id")
        #expect(session.jumpHost == "jump")
        #expect(try #require(Self.detect(["ssh", "-t", "host", "-o", "Port=2200", "tmux"])).port == 2200)
        // Options after the remote command do not reach the connection.
        #expect(try #require(Self.detect(["ssh", "-t", "host", "ls", "-p", "2222"])).port == nil)
    }

    /// OpenSSH keeps the first value it reads for a setting, wherever it is.
    @Test func theFirstValueOfASettingWins() throws {
        #expect(try #require(Self.detect(["ssh", "-p", "2222", "host", "-p", "3333"])).port == 2222)
        #expect(try #require(Self.detect(["ssh", "host", "-o", "Port=2222", "-p", "3333"])).port == 2222)
        #expect(try #require(Self.detect(["ssh", "-l", "alice", "host", "-l", "bob"])).destination == "alice@host")
        #expect(try #require(Self.detect(["ssh", "-o", "User=carol", "host", "-l", "bob"])).destination == "carol@host")
    }

    /// `-S` is the exception: each one replaces the control path, including one
    /// set by `-o ControlPath=`, while a later `-o ControlPath=` does not replace it
    /// (`ssh -G` reports `/b`, `/b` and `/a` for these). The upload rides this
    /// socket, so the wrong one could send it through another host's master.
    @Test func theLastControlPathFlagWins() throws {
        #expect(try #require(Self.detect(["ssh", "-S", "/a", "host", "-S", "/b"])).controlPath == "/b")
        #expect(try #require(Self.detect(["ssh", "-o", "ControlPath=/a", "host", "-S", "/b"])).controlPath == "/b")
        #expect(try #require(Self.detect(["ssh", "-S", "/a", "host", "-o", "ControlPath=/b"])).controlPath == "/a")
    }

    /// Restore replays an interactive ssh's argv; a shell-less one stays out.
    @Test func restoreTreatsOptionsAfterTheDestinationTheSameWay() {
        func binding(_ arguments: [String]) -> SurfaceResumeBindingSnapshot? {
            TerminalSSHSessionDetector.resumeBinding(
                processName: "ssh", processPath: "/usr/bin/ssh", arguments: arguments, environment: [:]
            )
        }
        #expect(binding(["ssh", "host", "-p", "2222"]) != nil)
        #expect(binding(["ssh", "host", "-N"]) == nil)
        #expect(binding(["ssh", "host", "uname", "-a"]) == nil)
    }

    private static func detect(_ arguments: [String]) -> DetectedSSHSession? {
        TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [.init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "ssh")],
            argumentsByPID: [2145: arguments]
        )
    }
}
