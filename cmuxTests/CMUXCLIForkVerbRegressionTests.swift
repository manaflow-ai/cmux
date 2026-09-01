import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CMUXCLIForkVerbRegressionTests {
    @Test
    func contextMenuForkQueuesForkVerbAndStagesParentRecord() throws {
        let workspace = Workspace()
        let sourcePanelID = try #require(workspace.focusedPanelId)
        let sourcePaneID = try #require(workspace.paneId(forPanelId: sourcePanelID))
        let sourceTabID = try #require(workspace.surfaceIdFromPanelId(sourcePanelID))
        let sessionID = "019dad34-d218-7943-b81a-eddac5c87951"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionID,
            workingDirectory: "/tmp/fork verb repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude"],
                workingDirectory: "/tmp/fork verb repo",
                environment: nil,
                capturedAt: 123,
                source: "test"
            )
        )
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelID)
        let sourceTab = try #require(
            workspace.bonsplitController.tabs(inPane: sourcePaneID).first { $0.id == sourceTabID }
        )

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .forkConversationNewTab,
            for: sourceTab,
            inPane: sourcePaneID
        )

        let forkPanelID = try #require(workspace.focusedPanelId)
        let forkPanel = try #require(workspace.terminalPanel(for: forkPanelID))
        #expect(forkPanel.surface.initialInput == " cmux fork claude \(sessionID)\n")
        #expect(workspace.restoredAgentSnapshotsByPanelId[forkPanelID] == snapshot)
    }

    @Test
    func cliForkVerbExecutesStructuredForkArguments() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-fork-verb-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("fork-agent", isDirectory: false)
        let marker = root.appendingPathComponent("fork-agent-output", isDirectory: false)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try """
        #!/bin/sh
        {
          printf 'pwd=%s\\n' "$PWD"
          printf 'value=%s\\n' "$FORK_TEST_VALUE"
          for argument in "$@"; do printf 'arg=%s\\n' "$argument"; done
        } > "$FORK_TEST_MARKER"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let surfaceID = UUID().uuidString.lowercased()
        let checkpointID = "fork-checkpoint"
        let responseData = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "result": [
                "restore_record": [
                    "mode": "resumeAgent",
                    "kind": "custom-agent",
                    "checkpoint_id": checkpointID,
                    "source": "session-snapshot",
                    "working_directory": root.path,
                    "environment": ["FORK_TEST_VALUE": "structured value"],
                    "launch_command": [
                        "arguments": [executable.path],
                        "executable_path": executable.path,
                        "working_directory": root.path,
                        "environment": ["FORK_TEST_VALUE": "structured value"],
                    ],
                    "fork_arguments": [executable.path, "--fork", checkpointID],
                ],
            ],
        ])
        let socketPath = "/tmp/cmux-fork-verb-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: String(decoding: responseData, as: UTF8.self)
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["FORK_TEST_MARKER"] = marker.path
        environment["PATH"] = "/usr/bin:/bin"

        let result = try runCLI(
            arguments: ["fork", "--surface", surfaceID, "custom-agent", checkpointID],
            environment: environment
        )
        #expect(result.status == 0, result.description)
        let output = try String(contentsOf: marker, encoding: .utf8)
        #expect(output.contains("pwd=\(root.path)"))
        #expect(output.contains("value=structured value"))
        #expect(output.contains("arg=--fork"))
        #expect(output.contains("arg=\(checkpointID)"))
        #expect(responder.receivedRequests.count == 1)
        #expect(responder.receivedRequests.first?.contains("surface.resume.get") == true)
    }

    private struct ProcessResult: CustomStringConvertible {
        let status: Int32
        let stdout: String
        let stderr: String

        var description: String {
            "status=\(status) stdout=\(stdout) stderr=\(stderr)"
        }
    }

    private func runCLI(
        arguments: [String],
        environment: [String: String]
    ) throws -> ProcessResult {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: Self.self)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
