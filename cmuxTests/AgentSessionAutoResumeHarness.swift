import Foundation
import CmuxCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentSessionAutoResumeHarness {
    enum HarnessError: Error {
        case missingInitialCommand
        case unexpectedInitialCommand(String)
    }

    @MainActor
    func resumeLauncherScript(from panel: TerminalPanel) throws -> String {
        guard let command = panel.surface.debugInitialCommand() else {
            throw HarnessError.missingInitialCommand
        }
        let prefix = "/bin/zsh "
        guard command.hasPrefix(prefix + "'") else {
            throw HarnessError.unexpectedInitialCommand(command)
        }
        let scriptPath = singleUnquotedShellWord(String(command.dropFirst(prefix.count)))
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        return try String(contentsOfFile: scriptPath, encoding: .utf8)
    }

    func singleUnquotedShellWord(_ value: String) -> String {
        guard value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 else { return value }
        let inner = value.dropFirst().dropLast()
        return inner.replacingOccurrences(of: "'\\''", with: "'")
    }

    func makeRestorableAgentIndex(
        workspaceId: UUID,
        panelId: UUID,
        sessionId: String,
        extraArguments: [String] = []
    ) throws -> RestorableAgentSessionIndex {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-auto-resume-\(UUID().uuidString)", isDirectory: true)
        let previousHookStateDir = getenv("CMUX_AGENT_HOOK_STATE_DIR").map { String(cString: $0) }
        setenv("CMUX_AGENT_HOOK_STATE_DIR", home.appendingPathComponent("hook-state", isDirectory: true).path, 1)
        defer {
            if let previousHookStateDir {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDir, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
        }
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex", "--model", "gpt-5.4"] + extraArguments,
                        "workingDirectory": "/tmp/repo",
                        "environment": ["CODEX_HOME": "/tmp/codex"],
                        "capturedAt": Date().timeIntervalSince1970,
                        "source": "process",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)
        return RestorableAgentSessionIndex.load(homeDirectory: home.path)
    }
}
