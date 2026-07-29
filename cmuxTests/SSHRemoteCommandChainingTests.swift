import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SSHRemoteCommandChainingTests {
    @Test
    func resolvedSSHConfigurationDistinguishesConfiguredCommandFromNone() {
        let cli = CMUXCLI(args: [])
        let configured = """
        hostname example.internal
        remotecommand cd "/scratch/project dir" && exec fish
        requesttty true
        """

        #expect(
            cli.resolvedUserSSHRemoteCommand(fromSSHConfigOutput: configured)
                == #"cd "/scratch/project dir" && exec fish"#
        )
        #expect(
            cli.resolvedUserSSHRemoteCommand(
                fromSSHConfigOutput: "remotecommand none\nrequesttty auto\n"
            ) == nil
        )
    }

    @Test
    func interactiveBootstrapExecutesConfiguredRemoteCommandAfterSetup() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-remote-command-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workingDirectory = home.appendingPathComponent("project dir", isDirectory: true)
        let helper = root.appendingPathComponent("persistent-pty-exec-helper")
        let resultFile = home.appendingPathComponent("remote-command-result")
        let helperMarker = home.appendingPathComponent("persistent-helper-used")
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        [ "${1:-}" = "--internal-persistent-pty-exec" ] || exit 2
        shift
        executable="${1:-}"
        [ -n "$executable" ] || exit 2
        shift
        [ "${1:-}" = "$executable" ] || exit 2
        shift
        printf 'yes\n' > "$HOME/persistent-helper-used"
        exec "$executable" "$@"
        """
        .write(to: helper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let configuredRemoteCommand = """
        cd "$HOME/project dir" && printf '%s\\n' "command 'ran'" "$CMUX_SOCKET_PATH" "$PWD" > "$HOME/remote-command-result"
        """
        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 64_123,
            shellFeatures: "ssh-env,ssh-terminfo",
            configuredRemoteCommand: configuredRemoteCommand
        )
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "-i",
            "HOME=\(home.path)",
            "SHELL=/bin/sh",
            "PATH=/usr/bin:/bin",
            "USER=\(NSUserName())",
            "CMUX_PERSISTENT_PTY_EXEC_HELPER=\(helper.path)",
            "/bin/sh",
            "-c",
            script,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let stderr = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0, Comment(rawValue: stderr))
        #expect(
            try String(contentsOf: helperMarker, encoding: .utf8) == "yes\n",
            "Configured commands must retain persistent-PTY hangup protection"
        )
        #expect(
            try String(contentsOf: resultFile, encoding: .utf8)
                == "command 'ran'\n127.0.0.1:64123\n\(workingDirectory.path)\n"
        )
    }
}
