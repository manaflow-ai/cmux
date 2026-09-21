import Darwin
import Foundation
import Testing

import CmuxControlSocket
import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteSession
import CmuxRemoteWorkspace
import CmuxSidebar
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SSHRemoteCWDRegressionTests {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    private func writeExecutableShellFile(at url: URL, body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test
    func generatedBashBootstrapChangesToInitialRemoteWorkingDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-initial-remote-cwd-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let initialWorkingDirectory = root.appendingPathComponent("remote-project")
        let capturedPWD = root.appendingPathComponent("pwd.txt")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: initialWorkingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(at: bin.appendingPathComponent("bash"), body: """
            #!/bin/sh
            rcfile=
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --rcfile) shift; rcfile="${1:-}" ;;
              esac
              shift || true
            done
            if [ -n "$rcfile" ]; then . "$rcfile"; fi
            printf '%s\\n' "$PWD" > "$CMUX_CAPTURE_PWD"
            """)
        let helper = bin.appendingPathComponent("persistent-pty-exec-helper")
        try writeExecutableShellFile(at: helper, body: """
            #!/bin/sh
            [ "${1:-}" = "--internal-persistent-pty-exec" ] || exit 2
            shift
            executable="${1:-}"
            [ -n "$executable" ] || exit 2
            shift
            [ "${1:-}" = "$executable" ] || exit 2
            shift
            exec "$executable" "$@"
            """)

        let encodedWorkingDirectory = Data(initialWorkingDirectory.path.utf8).base64EncodedString()
        let script = RemoteInteractiveShellBootstrapBuilder.script(remoteRelayPort: 0, shellFeatures: "")
            .replacingOccurrences(of: "__CMUX_REMOTE_INITIAL_CWD_B64__", with: encodedWorkingDirectory)
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)", "SHELL=\(bin.appendingPathComponent("bash").path)",
                "PATH=\(bin.path):/usr/bin:/bin", "TERM=xterm-256color", "USER=\(NSUserName())",
                "CMUX_CAPTURE_PWD=\(capturedPWD.path)", "CMUX_PERSISTENT_PTY_EXEC_HELPER=\(helper.path)",
                "/bin/sh", "-c", script,
            ],
            timeout: 5
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let captured = try String(contentsOf: capturedPWD, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(captured == initialWorkingDirectory.path)
    }

    @Test
    func generatedBashBootstrapDoesNotReuseAnotherPaneWorkingDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-shared-remote-cwd-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let firstWorkingDirectory = root.appendingPathComponent("first")
        let secondWorkingDirectory = root.appendingPathComponent("second")
        let capturedPWD = root.appendingPathComponent("pwd.txt")
        let secondBootstrap = root.appendingPathComponent("second-bootstrap.sh")
        let helperMarker = root.appendingPathComponent("helper-ran")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: firstWorkingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondWorkingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(at: bin.appendingPathComponent("bash"), body: """
            #!/bin/sh
            rcfile=
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --rcfile) shift; rcfile="${1:-}" ;;
              esac
              shift || true
            done
            if [ -n "$rcfile" ]; then . "$rcfile"; fi
            printf '%s\\n' "$PWD" >> "$CMUX_CAPTURE_PWD"
            """)
        try writeExecutableShellFile(at: bin.appendingPathComponent("persistent-pty-exec-helper"), body: """
            #!/bin/sh
            [ "${1:-}" = "--internal-persistent-pty-exec" ] || exit 2
            shift
            executable="${1:-}"
            [ -n "$executable" ] || exit 2
            shift
            [ "${1:-}" = "$executable" ] || exit 2
            shift
            if [ ! -e "$CMUX_HELPER_MARKER" ]; then
              : > "$CMUX_HELPER_MARKER"
              /bin/sh "$CMUX_SECOND_BOOTSTRAP"
            fi
            exec "$executable" "$@"
            """)

        func bootstrap(for directory: URL) -> String {
            let encodedDirectory = Data(directory.path.utf8).base64EncodedString()
            return RemoteInteractiveShellBootstrapBuilder.script(remoteRelayPort: 0, shellFeatures: "")
                .replacingOccurrences(of: "__CMUX_REMOTE_INITIAL_CWD_B64__", with: encodedDirectory)
        }
        try writeExecutableShellFile(at: secondBootstrap, body: bootstrap(for: secondWorkingDirectory))
        let helper = bin.appendingPathComponent("persistent-pty-exec-helper")
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)", "SHELL=\(bin.appendingPathComponent("bash").path)",
                "PATH=\(bin.path):/usr/bin:/bin", "TERM=xterm-256color", "USER=\(NSUserName())",
                "CMUX_CAPTURE_PWD=\(capturedPWD.path)", "CMUX_HELPER_MARKER=\(helperMarker.path)",
                "CMUX_SECOND_BOOTSTRAP=\(secondBootstrap.path)", "CMUX_PERSISTENT_PTY_EXEC_HELPER=\(helper.path)",
                "/bin/sh", "-c", bootstrap(for: firstWorkingDirectory),
            ],
            timeout: 5
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let captured = try String(contentsOf: capturedPWD, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        #expect(captured == [secondWorkingDirectory.path, firstWorkingDirectory.path])
    }

    @MainActor
    private func makeRemoteWorkspace(relayPort: Int) -> Workspace {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini", port: nil, identityFile: nil, sshOptions: [], localProxyPort: nil,
                relayPort: relayPort, relayID: String(repeating: "a", count: 16), relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-test.sock", terminalStartupCommand: "ssh-pty-attach", preserveAfterTerminalExit: true
            ),
            autoConnect: false
        )
        return workspace
    }

    @Test @MainActor
    func remoteTerminalSplitInheritsSelectedPanelWorkingDirectory() throws {
        let workspace = makeRemoteWorkspace(relayPort: 64016)
        let sourcePanelID = try #require(workspace.focusedTerminalPanel?.id)
        let selectedPanelDirectory = "/srv/cmux/selected-\(UUID().uuidString)"
        workspace.currentDirectory = "/srv/cmux/stale-\(UUID().uuidString)"
        #expect(workspace.updateRemotePanelDirectory(panelId: sourcePanelID, directory: selectedPanelDirectory))
        let splitPanel = try #require(workspace.newTerminalSplit(from: sourcePanelID, orientation: .vertical, focus: false))
        #expect(splitPanel.requestedWorkingDirectory == nil)
        #expect(splitPanel.surface.startupEnvironmentValue("CMUX_REMOTE_INITIAL_CWD") == selectedPanelDirectory)
    }

    @Test @MainActor
    func remoteTerminalSplitInheritsStartupWorkingDirectoryBeforeCwdReport() throws {
        let workspace = makeRemoteWorkspace(relayPort: 64019)
        let paneID = try #require(workspace.bonsplitController.allPaneIds.first)
        let sourceDirectory = "/srv/cmux/startup-before-report"
        let sourcePanel = try #require(workspace.newTerminalSurface(
            inPane: paneID, focus: true, initialCommand: "cmux ssh-pty-attach",
            startupEnvironment: [Workspace.remoteInitialWorkingDirectoryEnvironmentKey: sourceDirectory],
            remotePTYSessionID: "startup-cwd-source-session"
        ))
        #expect(workspace.isRemoteTerminalSurface(sourcePanel.id))
        #expect(workspace.panelDirectories[sourcePanel.id] == nil)
        let splitPanel = try #require(workspace.newTerminalSplit(from: sourcePanel.id, orientation: .vertical, focus: false))
        #expect(splitPanel.requestedWorkingDirectory == nil)
        #expect(splitPanel.surface.startupEnvironmentValue("CMUX_REMOTE_INITIAL_CWD") == sourceDirectory)
    }

    @Test @MainActor
    func remoteTerminalSplitOmitsUntrustedWorkspaceWorkingDirectory() throws {
        let workspace = makeRemoteWorkspace(relayPort: 64017)
        workspace.currentDirectory = "/srv/cmux/untrusted-workspace-directory"
        let sourcePanelID = try #require(workspace.focusedTerminalPanel?.id)
        let splitPanel = try #require(workspace.newTerminalSplit(from: sourcePanelID, orientation: .vertical, focus: false))
        #expect(splitPanel.requestedWorkingDirectory == nil)
        #expect(splitPanel.surface.startupEnvironmentValue("CMUX_REMOTE_INITIAL_CWD") == nil)
    }

    @Test @MainActor
    func remoteTerminalSurfaceRespectsWorkingDirectoryFallbackFlag() throws {
        let workspace = makeRemoteWorkspace(relayPort: 64018)
        let paneID = try #require(workspace.bonsplitController.allPaneIds.first)
        let sourcePanelID = try #require(workspace.focusedTerminalPanel?.id)
        #expect(workspace.updateRemotePanelDirectory(panelId: sourcePanelID, directory: "/srv/cmux/selected"))
        let withoutFallback = try #require(workspace.newTerminalSurface(inPane: paneID, focus: false, inheritWorkingDirectoryFallback: false))
        #expect(withoutFallback.requestedWorkingDirectory == nil)
        #expect(withoutFallback.surface.startupEnvironmentValue("CMUX_REMOTE_INITIAL_CWD") == nil)
        let explicitDirectory = "/srv/cmux/explicit"
        let withExplicitDirectory = try #require(workspace.newTerminalSurface(
            inPane: paneID, focus: false, workingDirectory: explicitDirectory, inheritWorkingDirectoryFallback: false
        ))
        #expect(withExplicitDirectory.requestedWorkingDirectory == nil)
        #expect(withExplicitDirectory.surface.startupEnvironmentValue("CMUX_REMOTE_INITIAL_CWD") == explicitDirectory)
    }

    @Test @MainActor
    func remoteStartupDoesNotRetainStaleInitialWorkingDirectory() throws {
        let workspace = makeRemoteWorkspace(relayPort: 64019)
        workspace.workspaceEnvironment[Workspace.remoteInitialWorkingDirectoryEnvironmentKey] = "/srv/cmux/stale"
        let sourcePanelID = try #require(workspace.focusedTerminalPanel?.id)
        let splitPanel = try #require(workspace.newTerminalSplit(from: sourcePanelID, orientation: .vertical, focus: false))
        #expect(splitPanel.surface.startupEnvironmentValue("CMUX_REMOTE_INITIAL_CWD") == nil)
        let paneID = try #require(workspace.bonsplitController.allPaneIds.first)
        let explicitDirectory = "/srv/cmux/explicit-environment"
        let surface = try #require(workspace.newTerminalSurface(
            inPane: paneID, focus: false,
            startupEnvironment: [Workspace.remoteInitialWorkingDirectoryEnvironmentKey: explicitDirectory]
        ))
        #expect(surface.surface.startupEnvironmentValue("CMUX_REMOTE_INITIAL_CWD") == explicitDirectory)
    }
}
