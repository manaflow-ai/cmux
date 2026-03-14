import XCTest

#if canImport(cmux)
@testable import cmux

final class CLIProcessRunnerTests: XCTestCase {
    func testRunProcessTimesOutHungChild() {
        let startedAt = Date()
        let result = CLIProcessRunner.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 5"],
            timeout: 0.2
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, 124)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2.0)
    }

    func testInteractiveRemoteShellCommandHonorsZDOTDIRFromRealZshenv() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-cli-zdotdir-\(UUID().uuidString)")
        let userZdotdir = home.appendingPathComponent("user-zdotdir")
        let relayDir = home.appendingPathComponent(".cmux/relay")
        let binDir = home.appendingPathComponent(".cmux/bin")
        try fileManager.createDirectory(at: userZdotdir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        try "export ZDOTDIR=\"$HOME/user-zdotdir\"\n"
            .write(to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try """
        precmd() {
          print -r -- "REAL=$CMUX_REAL_ZDOTDIR ZDOTDIR=$ZDOTDIR SOCKET=$CMUX_SOCKET_PATH PATH=$PATH"
          exit
        }
        """
        .write(to: userZdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n"
            .write(to: binDir.appendingPathComponent("cmux"), atomically: true, encoding: .utf8)
        try "".write(
            to: relayDir.appendingPathComponent("64003.auth"),
            atomically: true,
            encoding: .utf8
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binDir.appendingPathComponent("cmux").path
        )

        let cli = CMUXCLI(args: [])
        let command = cli.buildInteractiveRemoteShellCommand(remoteRelayPort: 64003, shellFeatures: "")
        let result = CLIProcessRunner.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("REAL=\(userZdotdir.path)"), result.stdout)
        XCTAssertTrue(result.stdout.contains("SOCKET=127.0.0.1:64003"), result.stdout)
        XCTAssertTrue(result.stdout.contains("PATH=\(binDir.path):"), result.stdout)
        XCTAssertTrue(result.stdout.contains("ZDOTDIR=\(relayDir.appendingPathComponent("64003.shell").path)"), result.stdout)
    }

    func testInteractiveRemoteShellCommandKeepsDefaultZDOTDIRWithoutRecursing() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-cli-zdotdir-default-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay")
        let binDir = home.appendingPathComponent(".cmux/bin")
        try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        try "precmd() { print -r -- \"REAL=$CMUX_REAL_ZDOTDIR ZDOTDIR=$ZDOTDIR\"; exit }\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n"
            .write(to: binDir.appendingPathComponent("cmux"), atomically: true, encoding: .utf8)
        try "".write(
            to: relayDir.appendingPathComponent("64004.auth"),
            atomically: true,
            encoding: .utf8
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binDir.appendingPathComponent("cmux").path
        )

        let cli = CMUXCLI(args: [])
        let command = cli.buildInteractiveRemoteShellCommand(remoteRelayPort: 64004, shellFeatures: "")
        let result = CLIProcessRunner.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(result.stderr.contains("too many open files"), result.stderr)
        XCTAssertTrue(result.stdout.contains("REAL=\(home.path)"), result.stdout)
        XCTAssertTrue(result.stdout.contains("ZDOTDIR=\(relayDir.appendingPathComponent("64004.shell").path)"), result.stdout)
    }
}
#endif
