import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite("Agent resume return shell startup")
struct AgentResumeReturnShellStartupTests {
    @Test("local resume input is one short readable CLI command")
    func localResumeInputUsesRestoreVerb() {
        let sessionID = "019dad34-d218-7943-b81a-eddac5c87951"
        let agentBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID) \(String(repeating: "--config x=y ", count: 200))",
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true
        )
        let manualBinding = SurfaceResumeBindingSnapshot(
            name: "CLI binding",
            command: "printf done >/dev/null # \(String(repeating: "x", count: 4_000))",
            source: "cli",
            autoResume: true
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: "/tmp/项目 with spaces",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--add-dir",
                    "quote' and 日本語",
                    String(repeating: "nested-path-", count: 200),
                ],
                workingDirectory: "/tmp/项目 with spaces"
            )
        )

        #expect(
            agentBinding.restoreStartupInput(
                repairPortableAgentExecutable: true
            )
                == " cmux restore codex \(sessionID)\n"
        )
        #expect(
            manualBinding.restoreStartupInput(
                repairPortableAgentExecutable: true
            )
                == " cmux restore --surface\n"
        )
        #expect(
            snapshot.resumeStartupInput()
                == " cmux restore codex \(sessionID)\n"
        )
    }

    @Test("unsafe identifiers use the ASCII-only surface selector")
    func unsafeIdentifiersUseSurfaceSelector() {
        let snapshots = [
            SessionRestorableAgentSnapshot(
                kind: .custom("代理 agent"),
                sessionId: "会話 'one'"
            ),
            SessionRestorableAgentSnapshot(
                kind: .custom("-beta"),
                sessionId: "checkpoint"
            ),
            SessionRestorableAgentSnapshot(
                kind: .custom("agent"),
                sessionId: "--checkpoint"
            ),
        ]

        for snapshot in snapshots {
            #expect(
                snapshot.resumeStartupInput()
                    == " \(AgentRestoreLaunch.cliStartupExecutableToken) restore --surface\n"
            )
        }
    }

    @Test("non-restore one-shot launchers retain their storage policy")
    func nonRestoreOneShotLauncherStoragePolicy() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-9258-store-\(UUID().uuidString)", isDirectory: true)
        let launcherDirectory = root.appendingPathComponent("cmux-r", isDirectory: true)
        let staleLauncher = launcherDirectory.appendingPathComponent("stale.zsh", isDirectory: false)
        let currentLauncher = launcherDirectory.appendingPathComponent("current.zsh", isDirectory: false)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try fileManager.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try "#!/bin/zsh\n:\n".write(to: staleLauncher, atomically: true, encoding: .utf8)
        try "#!/bin/zsh\n:\n".write(to: currentLauncher, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(25 * 60 * 60))],
            ofItemAtPath: staleLauncher.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(23 * 60 * 60))],
            ofItemAtPath: currentLauncher.path
        )
        defer { try? fileManager.removeItem(at: root) }

        let launcher = try #require(OneShotTerminalLauncherStore(
            fileManager: fileManager,
            temporaryDirectory: root,
            currentDate: now
        ).writeLauncherScript(
            command: ":",
            workingDirectory: nil
        ))

        #expect(!fileManager.fileExists(atPath: staleLauncher.path))
        #expect(fileManager.fileExists(atPath: currentLauncher.path))
        let directoryMode = try #require(
            fileManager.attributesOfItem(atPath: launcherDirectory.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        let launcherMode = try #require(
            fileManager.attributesOfItem(atPath: launcher.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        #expect(directoryMode == 0o700)
        #expect(launcherMode == 0o600)
    }
}
