import CmuxMobileSSH
@testable import CmuxiOSSSHCore
import Foundation
import Testing

@Suite struct SSHCmuxTUIAttachTests {
    private let discovery = SSHSessionDiscovery()

    @Test func attachesToTheDiscoveredSocketInsteadOfDerivingOneFromTheSSHEnvironment() throws {
        // A macOS owner started in Terminal may use DARWIN_USER_TEMP_DIR,
        // while the new SSH login would derive a different socket in /tmp.
        let path = "/var/folders/xy/owner/T/cmux-tui-501/work.sock"
        let session = try #require(discovery.parse("@cmux-tui\t/usr/local/bin/cmux-tui\nC\t\(path)\n").first)
        #expect(session.target.attachCommand == "exec '/usr/local/bin/cmux-tui' attach --socket '\(path)'")
        #expect(session.id == "ssh:cmux-tui:work")
        #expect(session.target.surfaceID == session.id)
    }

    @Test func runtimePrecedenceKeepsTheFirstValidSocketForTheSession() throws {
        let output = """
        @cmux-tui\t/usr/local/bin/cmux-tui
        C\trelative/cmux-tui-501/work.sock
        C\t/var/folders/xy/owner/T/cmux-tui-501/work.sock
        C\t/tmp/cmux-tui-501/work.sock
        C\t/var/folders/xy/owner/T/cmux-tui-501/work.sock
        """
        let sessions = discovery.parse(output)
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.target.attachCommand
            == "exec '/usr/local/bin/cmux-tui' attach --socket '/var/folders/xy/owner/T/cmux-tui-501/work.sock'")
    }

    @Test(arguments: [
        "relative/cmux-tui-501/work.sock", "/tmp/cmux-tui-501/../work.sock",
        "/tmp/cmux-tui-501/./work.sock", "/tmp/not-cmux/work.sock",
        "/tmp/cmux-tui-evil/work.sock", "/tmp/cmux-tui-/work.sock",
        "/tmp/cmux-tui-501/-evil.sock", "/tmp/cmux-tui-501/.sock",
        "/tmp/\u{0}/cmux-tui-501/work.sock", "/tmp/\t/cmux-tui-501/work.sock",
    ])
    func malformedSocketPathsCannotBecomeAttachTargets(_ path: String) {
        #expect(discovery.parse("@cmux-tui\t/usr/local/bin/cmux-tui\nC\t\(path)\n").isEmpty)
    }

    @Test func socketPathsAreShellQuotedWithoutLosingDirectoryNames() throws {
        let path = "/Users/O'Brien/Library/Application Support/cmux-tui-501/work.sock"
        let session = try #require(discovery.parse("@cmux-tui\t/usr/local/bin/cmux-tui\nC\t\(path)\n").first)
        #expect(session.target.attachCommand
            == "exec '/usr/local/bin/cmux-tui' attach --socket '/Users/O'\\''Brien/Library/Application Support/cmux-tui-501/work.sock'")
    }
}
