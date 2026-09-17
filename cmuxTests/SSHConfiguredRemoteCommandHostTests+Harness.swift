import CmuxFoundation
import Darwin
import Foundation
import Testing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SSHConfiguredRemoteCommandHostTests {
    // MARK: - Fake RemoteCommand-host harness

    struct RemoteCommandHostHarness {
        let root: URL
        let binDirectory: URL
        let eventsFile: URL
        let fakeCLILog: URL

        func startupEnvironment(
            socketPath: String,
            workspaceID: String,
            surfaceID: String
        ) -> [String: String] {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin"
            environment["CMUX_BUNDLED_CLI_PATH"] = binDirectory.appendingPathComponent("cmux").path
            environment["CMUX_SOCKET_PATH"] = socketPath
            environment["CMUX_WORKSPACE_ID"] = workspaceID
            environment["CMUX_SURFACE_ID"] = surfaceID
            environment["CMUX_FAKE_SSH_EVENTS"] = eventsFile.path
            environment["CMUX_FAKE_CLI_LOG"] = fakeCLILog.path
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
            environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
            environment["CMUX_SSH_RECONNECT_LIMIT"] = "1"
            environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"
            return environment
        }

        func startupCommandUsingFakeSSH(_ startupCommand: String) throws -> String {
            let systemSSHPath = "/usr/bin/ssh"
            let fakeSSHPath = binDirectory.appendingPathComponent("ssh").path
            let trimmedCommand = startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            let commandURL = URL(fileURLWithPath: trimmedCommand)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false

            if FileManager.default.fileExists(atPath: commandURL.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                let contents = try String(contentsOf: commandURL, encoding: .utf8)
                guard contents.contains(systemSSHPath) else {
                    throw NSError(
                        domain: "SSHConfiguredRemoteCommandHostTests",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Generated startup script did not pin \(systemSSHPath)"]
                    )
                }
                let rewrittenURL = root.appendingPathComponent("startup-with-fake-ssh.sh")
                try contents
                    .replacingOccurrences(of: systemSSHPath, with: fakeSSHPath)
                    .write(to: rewrittenURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: rewrittenURL.path
                )
                return rewrittenURL.path
            }

            guard startupCommand.contains(systemSSHPath) else {
                if let rewritten = SSHStartupCommandTestSupport.replacingPinnedSSH(
                    in: startupCommand, with: fakeSSHPath
                ) {
                    return rewritten
                }
                throw NSError(
                    domain: "SSHConfiguredRemoteCommandHostTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Generated startup command did not pin \(systemSSHPath)"]
                )
            }
            return startupCommand.replacingOccurrences(of: systemSSHPath, with: fakeSSHPath)
        }

        func recordedSSHEvents() -> [String] {
            ((try? String(contentsOf: eventsFile, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .map(String.init)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Installs a fake `ssh` that enforces OpenSSH's configured-command
    /// conflict semantics, and a fake `cmux` for the startup script's
    /// session-end reporting. Tests first assert that the production artifact
    /// pins `/usr/bin/ssh`, then substitute this executable in that artifact.
    func makeRemoteCommandHostHarness(prefix: String) throws -> RemoteCommandHostHarness {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        let harness = RemoteCommandHostHarness(
            root: root,
            binDirectory: binDirectory,
            eventsFile: root.appendingPathComponent("fake-ssh-events.log"),
            fakeCLILog: root.appendingPathComponent("fake-cli.log")
        )

        // Mirrors OpenSSH: the first -o RemoteCommand=... wins; a positional
        // command with no override is fatal exactly like a host-configured
        // RemoteCommand conflict. `-G` prints a config dump and `-O` control
        // operations never execute a remote command.
        let fakeSSH = """
        #!/bin/sh
        events="${CMUX_FAKE_SSH_EVENTS:?}"
        override=absent
        remotecommand_value=
        remotecommand_options=0
        mode=session
        while [ $# -gt 0 ]; do
          case "$1" in
            -o)
              case "$2" in
                RemoteCommand=*|remotecommand=*)
                  remotecommand_options=$((remotecommand_options + 1))
                  remotecommand_value="${2#*=}"
                  ;;
              esac
              if [ "$override" = absent ]; then
                case "$2" in
                  RemoteCommand=none|remotecommand=none) override=none ;;
                  RemoteCommand=*|remotecommand=*) override=custom ;;
                esac
              fi
              shift 2 ;;
            -o*)
              case "${1#-o}" in
                RemoteCommand=*|remotecommand=*)
                  remotecommand_options=$((remotecommand_options + 1))
                  remotecommand_value="${1#*=}"
                  ;;
              esac
              if [ "$override" = absent ]; then
                case "${1#-o}" in
                  RemoteCommand=none|remotecommand=none) override=none ;;
                  RemoteCommand=*|remotecommand=*) override=custom ;;
                esac
              fi
              shift ;;
            -G) mode=config; shift ;;
            -O) mode=controlop; shift 2 ;;
            -S|-p|-i|-l|-F|-E|-e|-b|-c|-D|-I|-J|-L|-m|-Q|-R|-W|-w|-B) shift 2 ;;
            --) shift; shift; break ;;
            -*) shift ;;
            *) shift; break ;;
          esac
        done
        if [ "$mode" = config ]; then
          printf 'invocation kind=config override=%s\\n' "$override" >> "$events"
          printf 'controlpath none\\n'
          case "$override" in
            custom) printf 'remotecommand %s\\n' "$remotecommand_value" ;;
            none) printf 'remotecommand none\\n' ;;
            *) printf 'remotecommand sudo su -\\n' ;;
          esac
          printf 'requesttty yes\\n'
          exit 0
        fi
        if [ "$mode" = controlop ]; then
          printf 'invocation kind=controlop override=%s\\n' "$override" >> "$events"
          exit 0
        fi
        if [ $# -gt 0 ]; then mode=command; fi
        printf 'invocation kind=%s override=%s\\n' "$mode" "$override" >> "$events"
        printf 'remotecommand-options kind=%s count=%s\\n' "$mode" "$remotecommand_options" >> "$events"
        if [ "$mode" = command ] && [ "$override" = absent ]; then
          printf '%s\\n' 'Cannot execute command-line and remote command.' >&2
          exit 255
        fi
        cat >/dev/null 2>&1 || true
        exit 0
        """
        let fakeSSHURL = binDirectory.appendingPathComponent("ssh")
        try fakeSSH.appending("\n").write(to: fakeSSHURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSHURL.path)

        let fakeCLI = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "${CMUX_FAKE_CLI_LOG:?}"
        exit 0
        """
        let fakeCLIURL = binDirectory.appendingPathComponent("cmux")
        try fakeCLI.appending("\n").write(to: fakeCLIURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLIURL.path)

        return harness
    }
}
