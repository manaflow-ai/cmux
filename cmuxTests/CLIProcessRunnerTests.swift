import XCTest

#if canImport(cmux)
@testable import cmux

final class CLIProcessRunnerTests: XCTestCase {
    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

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

    func testInteractiveRemoteShellCommandDoesNotWaitForRelayReadinessBeforeLaunchingShell() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-cli-no-relay-wait-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        try "precmd() { print -r -- \"READY SOCKET=$CMUX_SOCKET_PATH\"; exit }\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let cli = CMUXCLI(args: [])
        let command = cli.buildInteractiveRemoteShellCommand(remoteRelayPort: 64006, shellFeatures: "")
        let startedAt = Date()
        let result = CLIProcessRunner.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            timeout: 2
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("READY SOCKET=127.0.0.1:64006"), result.stdout)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5, "interactive shell startup should not wait for relay readiness")
    }

    func testInteractiveRemoteShellCommandDefaultsToXterm256ColorWithoutPreparedGhosttyTerminfo() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-cli-term-fallback-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        try "precmd() { print -r -- \"TERM=$TERM\"; exit }\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let cli = CMUXCLI(args: [])
        let command = cli.buildInteractiveRemoteShellCommand(remoteRelayPort: 0, shellFeatures: "")
        let result = CLIProcessRunner.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("TERM=xterm-256color"), result.stdout)
    }

    func testInteractiveRemoteShellCommandSourcesZprofileBeforeLaunchingInteractiveZsh() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-cli-zprofile-\(UUID().uuidString)")
        let brewBin = home.appendingPathComponent("testbrew/bin")
        try fileManager.createDirectory(at: brewBin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        try "export PATH=\"$HOME/testbrew/bin:$PATH\"\n"
            .write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try "precmd() { print -r -- \"PATH=$PATH\"; exit }\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let cli = CMUXCLI(args: [])
        let command = cli.buildInteractiveRemoteShellCommand(remoteRelayPort: 0, shellFeatures: "")
        let result = CLIProcessRunner.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("PATH=\(brewBin.path):"), result.stdout)
    }

    func testInteractiveRemoteShellCommandWithInlineTerminfoParsesAndLaunchesZsh() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-cli-inline-terminfo-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        try "precmd() { print -r -- \"READY TERM=$TERM\"; exit }\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let cli = CMUXCLI(args: [])
        let command = cli.buildInteractiveRemoteShellCommand(
            remoteRelayPort: 0,
            shellFeatures: "",
            terminfoSource: "xterm-ghostty|ghostty,clear=\\E[H\\E[2J"
        )
        let result = CLIProcessRunner.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("READY TERM="), result.stdout)
        XCTAssertFalse(result.stderr.contains("unexpected end of file"), result.stderr)
    }

    func testRemoteCLIWrapperPrefersRelaySpecificDaemonMapping() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-cli-wrapper-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay")
        let binDir = home.appendingPathComponent(".cmux/bin")
        let wrapperURL = binDir.appendingPathComponent("cmux")
        let currentDaemonURL = binDir.appendingPathComponent("cmuxd-remote-current")
        let mappedDaemonURL = binDir.appendingPathComponent("cmuxd-remote-64005")
        let daemonPathURL = relayDir.appendingPathComponent("64005.daemon_path")
        try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        try writeExecutable("#!/bin/sh\necho current \"$@\"\n", to: currentDaemonURL)
        try writeExecutable("#!/bin/sh\necho mapped \"$@\"\n", to: mappedDaemonURL)
        try writeExecutable(Workspace.remoteCLIWrapperScript(), to: wrapperURL)
        try mappedDaemonURL.path.write(to: daemonPathURL, atomically: true, encoding: .utf8)

        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "CMUX_SOCKET_PATH=127.0.0.1:64005",
                wrapperURL.path,
                "ping",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "mapped ping")
    }

    func testRemoteCLIWrapperInstallScriptDoesNotClobberLegacySymlinkedDaemonTarget() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-cli-wrapper-install-\(UUID().uuidString)")
        let binDir = home.appendingPathComponent(".cmux/bin")
        let daemonDir = binDir.appendingPathComponent("cmuxd-remote/0.62.1/darwin-arm64")
        let daemonURL = daemonDir.appendingPathComponent("cmuxd-remote")
        let currentDaemonURL = binDir.appendingPathComponent("cmuxd-remote-current")
        let wrapperURL = binDir.appendingPathComponent("cmux")
        try fileManager.createDirectory(at: daemonDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        try writeExecutable("#!/bin/sh\necho daemon \"$@\"\n", to: daemonURL)
        try fileManager.createSymbolicLink(atPath: currentDaemonURL.path, withDestinationPath: daemonURL.path)
        try fileManager.createSymbolicLink(atPath: wrapperURL.path, withDestinationPath: currentDaemonURL.path)

        let installScript = Workspace.remoteCLIWrapperInstallScript(
            daemonRemotePath: ".cmux/bin/cmuxd-remote/0.62.1/darwin-arm64/cmuxd-remote"
        )
        let installResult = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "/bin/sh",
                "-c",
                installScript,
            ],
            timeout: 5
        )

        XCTAssertFalse(installResult.timedOut, installResult.stderr)
        XCTAssertEqual(installResult.status, 0, installResult.stderr)
        XCTAssertEqual(
            try String(contentsOf: daemonURL, encoding: .utf8),
            "#!/bin/sh\necho daemon \"$@\"\n"
        )
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: currentDaemonURL.path),
            daemonURL.path
        )
        let wrapperAttributes = try fileManager.attributesOfItem(atPath: wrapperURL.path)
        XCTAssertEqual(wrapperAttributes[.type] as? FileAttributeType, .typeRegular)

        let wrapperResult = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                wrapperURL.path,
                "serve",
                "--stdio",
            ],
            timeout: 5
        )

        XCTAssertFalse(wrapperResult.timedOut, wrapperResult.stderr)
        XCTAssertEqual(wrapperResult.status, 0, wrapperResult.stderr)
        XCTAssertEqual(wrapperResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "daemon serve --stdio")
    }

    func testSSHStartupCommandBootstrapsOverRemoteCommandWithoutStealingInteractiveInput() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("cmux-cli-ssh-pty-\(UUID().uuidString)")
        let fakeBin = tempRoot.appendingPathComponent("bin")
        let argvURL = tempRoot.appendingPathComponent("ssh-argv.txt")
        let remoteCommandURL = tempRoot.appendingPathComponent("ssh-remote-command.txt")
        try fileManager.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        try writeExecutable(
            """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(argvURL.path)'
            remote_command=''
            while [ "$#" -gt 0 ]; do
              if [ "$1" = '-o' ] && [ "$#" -ge 2 ]; then
                case "$2" in
                  RemoteCommand=*)
                    remote_command=${2#RemoteCommand=}
                    ;;
                esac
                shift 2
                continue
              fi
              shift
            done
            printf '%s' "$remote_command" > '\(remoteCommandURL.path)'
            if [ -n "$remote_command" ]; then
              exec /bin/sh -lc "$remote_command"
            fi
            exec /bin/sh
            """,
            to: fakeBin.appendingPathComponent("ssh")
        )

        let cli = CMUXCLI(args: [])
        let sshCommand = cli.buildSSHCommandText(
            CMUXCLI.SSHCommandOptions(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                workspaceName: nil,
                sshOptions: [],
                extraArguments: [],
                localSocketPath: "",
                remoteRelayPort: 64007
            ),
            remoteBootstrapScript: """
            printf '%s\\n' 'BOOTSTRAPPED %{255}'
            exec /bin/sh
            """
        )
        let startupCommand = try cli.buildSSHStartupCommand(
            sshCommand: sshCommand,
            shellFeatures: "cursor:blink,path,title",
            remoteRelayPort: 64007
        )
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "PATH=\(fakeBin.path):\(currentPath)",
                "STARTUP=\(startupCommand)",
                "/usr/bin/python3",
                "-c",
                """
import os, pty, select, subprocess, time
startup = os.environ["STARTUP"]
env = os.environ.copy()
master, slave = pty.openpty()
proc = subprocess.Popen([startup], stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True)
os.close(slave)
time.sleep(0.4)
os.write(master, b"echo READY\\nexit\\n")
time.sleep(0.8)
out = b""
deadline = time.time() + 1.5
while time.time() < deadline:
    r, _, _ = select.select([master], [], [], 0.2)
    if not r:
        break
    try:
        chunk = os.read(master, 65536)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
try:
    proc.terminate()
except ProcessLookupError:
    pass
try:
    proc.wait(timeout=1)
except Exception:
    proc.kill()
print(out.decode("utf-8", "replace"), end="")
""",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("BOOTSTRAPPED %{255}"), result.stdout)
        XCTAssertTrue(result.stdout.contains("READY"), result.stdout)
        let argv = try String(contentsOf: argvURL, encoding: .utf8)
        XCTAssertTrue(argv.contains("RemoteCommand="), argv)
        let remoteCommand = try String(contentsOf: remoteCommandURL, encoding: .utf8)
        XCTAssertFalse(remoteCommand.contains("%{255}"), remoteCommand)
        XCTAssertTrue(remoteCommand.contains("base64"), remoteCommand)
    }

    func testEncodedRemoteBootstrapCommandEscapesPercentsForSSHRemoteCommand() throws {
        let cli = CMUXCLI(args: [])
        let remoteCommand = cli.sshPercentEscapedRemoteCommand(
            cli.encodedRemoteBootstrapCommand(
                """
                printf '%s\\n' 'BOOTSTRAPPED %{255}'
                exit 0
                """
            )
        )

        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/ssh",
            arguments: [
                "-G",
                "-o",
                "RemoteCommand=\(remoteCommand)",
                "cmux-macmini",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("host cmux-macmini"), result.stdout)
    }
}
#endif
