import CMUXAgentLaunch
import Darwin
import Foundation

/// Only the surrounding CLI shell is stubbed; restore planning and exec are production code.
struct CMUXCLI {
    struct RestoreRecord {
        let mode: String
        let kind: String
        let checkpointID: String?
        let workingDirectory: String?
        let launchCommand: AgentLaunchCommand?
    }

    struct RestoreError: Error, CustomStringConvertible {
        let description: String
    }

    func loggedRestoreError(
        stage: String,
        detail: String? = nil,
        errorCode: Int32? = nil,
        message: String
    ) -> RestoreError {
        RestoreError(description: "\(stage): \(message)")
    }
}

final class SocketClient {
    func close() {}
}

@main
struct RestoreHarness {
    static func main() {
        do {
            let cli = CMUXCLI()
            let args = CommandLine.arguments
            let environment = ProcessInfo.processInfo.environment
            let mode = args[1]
            let executable = args[2]
            let directory = args[3]
            let sessionID = args[4]
            let saved = ["CODEX_HOME": environment["SAVED_CODEX_HOME"] ?? environment["CODEX_HOME"]!]
            if mode == "legacy" || mode == "legacy-noncanonical" || mode == "ambiguous-legacy" || mode == "remote" {
                let remote = mode == "remote" ? " --remote ws://example.invalid" : ""
                let command = mode != "ambiguous-legacy"
                    ? "env CODEX_HOME='\(saved["CODEX_HOME"]!)' '\(executable)'\(remote) resume \(sessionID)"
                    : "'\(executable)' resume \(sessionID)"
                let recordMode = mode == "legacy-noncanonical" ? "resumeAgent " : "resumeAgent"
                let recordKind = mode == "legacy-noncanonical" ? " codex " : "codex"
                try cli.execLegacyRestoreRecord(
                    command,
                    record: CMUXCLI.RestoreRecord(
                        mode: recordMode, kind: recordKind, checkpointID: sessionID,
                        workingDirectory: directory, launchCommand: nil
                    ),
                    environment: environment, client: SocketClient()
                )
            } else {
                let applied = try cli.applyRestoreWorkingDirectory(directory)
                let launch = AgentLaunchCommand(
                    arguments: [executable, "--model", "model with spaces", "-c", "test='quoted value'"],
                    workingDirectory: directory, environment: saved, source: "test"
                )
                let request = AgentRestoreRequest(
                    mode: .resumeAgent, kind: mode == "other-provider" ? "claude" : "codex",
                    checkpointID: sessionID, source: "test", workingDirectory: applied,
                    environment: saved, launchCommand: mode == "remote" ? nil : launch,
                    preparedArguments: mode == "remote" ? [executable, "--remote", "ws://example.invalid", "resume", sessionID] : nil,
                    observedPermissionMode: nil
                )
                guard let invocation = AgentRestorePlanner(executableFileResolver: AgentRestoreExecutableFileResolver())
                    .invocation(for: request, ambientEnvironment: environment) else {
                    throw CMUXCLI.RestoreError(description: "fixture planning failed")
                }
                try cli.execRestoreInvocation(invocation, appliedWorkingDirectory: applied)
            }
            exit(90)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
