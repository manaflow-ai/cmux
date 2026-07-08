import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// "Save as Workspace Layout" persistence (JSONC upsert/removal into
/// cmux.json) and the foreground-command capture that feeds saved terminal
/// surfaces.
struct CmuxConfigActionSaverTests {

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-action-saver-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Slugs and ids

    @Test func slugForTitle() {
        #expect(CmuxConfigActionSaver.slug(forTitle: "My Dev Setup!") == "my-dev-setup")
        #expect(CmuxConfigActionSaver.slug(forTitle: "  --  ") == "workspace")
        #expect(CmuxConfigActionSaver.slug(forTitle: "日本語 Dev") == "日本語-dev")
    }

    @Test func uniqueActionID() {
        #expect(CmuxConfigActionSaver.uniqueActionID(forTitle: "Dev", existingIDs: []) == "dev")
        #expect(
            CmuxConfigActionSaver.uniqueActionID(forTitle: "Dev", existingIDs: ["dev", "dev-2"]) == "dev-3"
        )
    }

    // MARK: - Saving

    @Test func savePreservesCommentsAndDecodes() throws {
        let root = try temporaryRoot("comments")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("cmux.json").path
        let existing = """
        {
          // build actions
          "actions": {
            "dev": { "type": "command", "command": "make" } // keep me
          }
        }
        """
        try existing.write(toFile: configPath, atomically: true, encoding: .utf8)

        let definition = CmuxWorkspaceDefinition(
            name: "Dev",
            cwd: "~/code",
            setup: "make deps",
            layout: .pane(CmuxPaneDefinition(surfaces: [
                CmuxSurfaceDefinition(type: .terminal, command: "claude", focus: true)
            ]))
        )
        let result = try CmuxConfigActionSaver.saveWorkspaceAction(
            title: "Dev",
            definition: definition,
            globalConfigPath: configPath
        )
        #expect(result.actionID == "dev-2", "id should be uniquified against the existing 'dev'")

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.contains("// build actions"))
        #expect(saved.contains("// keep me"))

        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
        let inline = try #require(config.actions["dev-2"]?.action?.inlineWorkspace)
        #expect(inline.definition.name == "Dev")
        #expect(inline.definition.setup == "make deps")
        #expect(config.actions["dev-2"]?.title == "Dev")
        guard case .pane(let pane)? = inline.definition.layout else {
            Issue.record("Expected pane layout")
            return
        }
        #expect(pane.surfaces.first?.command == "claude")
    }

    @Test func saveRejectsNonObjectActionsBlock() throws {
        let root = try temporaryRoot("nonobject")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("cmux.json").path
        let original = "{\n  \"actions\": [\"not\", \"an\", \"object\"]\n}\n"
        try original.write(toFile: configPath, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try CmuxConfigActionSaver.saveWorkspaceAction(
                title: "Nope",
                definition: CmuxWorkspaceDefinition(name: "Nope"),
                globalConfigPath: configPath
            )
        }
        #expect(try String(contentsOfFile: configPath, encoding: .utf8) == original)
    }

    @Test func saveRejectsUnparseableConfig() throws {
        let root = try temporaryRoot("unparseable")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("cmux.json").path
        let original = "{ \"actions\": tru }\n"
        try original.write(toFile: configPath, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try CmuxConfigActionSaver.saveWorkspaceAction(
                title: "Nope",
                definition: CmuxWorkspaceDefinition(name: "Nope"),
                globalConfigPath: configPath
            )
        }
        // Broken user content must survive byte-identical.
        #expect(try String(contentsOfFile: configPath, encoding: .utf8) == original)
    }

    @Test func savePreservesSymlinkedConfig() throws {
        let root = try temporaryRoot("symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let realConfig = root.appendingPathComponent("dotfiles-cmux.json")
        try "{}\n".write(to: realConfig, atomically: true, encoding: .utf8)
        let linkPath = root.appendingPathComponent("cmux.json").path
        try FileManager.default.createSymbolicLink(
            atPath: linkPath,
            withDestinationPath: realConfig.path
        )

        _ = try CmuxConfigActionSaver.saveWorkspaceAction(
            title: "Linked",
            definition: CmuxWorkspaceDefinition(name: "Linked"),
            globalConfigPath: linkPath
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: linkPath)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        let saved = try String(contentsOf: realConfig, encoding: .utf8)
        #expect(saved.contains("\"linked\""))
    }

    @Test func saveRespectsReservedIDs() throws {
        let root = try temporaryRoot("reserved")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("cmux.json").path

        let result = try CmuxConfigActionSaver.saveWorkspaceAction(
            title: "Dev",
            definition: CmuxWorkspaceDefinition(name: "Dev"),
            globalConfigPath: configPath,
            reservedActionIDs: ["dev"]
        )
        #expect(result.actionID == "dev-2", "id reserved by the active store must not be reused")
    }

    @Test func saveCreatesFileFromTemplateOwnerOnly() throws {
        let root = try temporaryRoot("template")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("nested/cmux.json").path

        let result = try CmuxConfigActionSaver.saveWorkspaceAction(
            title: "Fresh",
            definition: CmuxWorkspaceDefinition(name: "Fresh"),
            globalConfigPath: configPath
        )
        #expect(result.actionID == "fresh")

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.contains("$schema"))
        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
        #expect(config.actions["fresh"]?.action?.inlineWorkspace != nil)

        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: configPath)[.posixPermissions] as? NSNumber
        )
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    // MARK: - Deleting

    @Test func deleteRemovesActionAndPreservesComments() throws {
        let root = try temporaryRoot("delete")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("cmux.json").path
        let existing = """
        {
          // build actions
          "actions": {
            "keep": { "type": "command", "command": "make" }, // keep me
            "gone": {
              "type": "workspace",
              "workspace": { "name": "Gone" }
            }
          },
          "commands": []
        }
        """
        try existing.write(toFile: configPath, atomically: true, encoding: .utf8)

        try CmuxConfigActionSaver.deleteAction(id: "gone", globalConfigPath: configPath)

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.contains("// build actions"))
        #expect(saved.contains("// keep me"))
        #expect(!saved.contains("\"gone\""))
        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
        #expect(config.actions.count == 1)
        #expect(config.actions["keep"] != nil)
    }

    @Test func deleteFirstOfTwoActionsKeepsValidJSON() throws {
        let root = try temporaryRoot("delete-first")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("cmux.json").path
        try """
        {
          "actions": {
            "first": { "type": "command", "command": "a" },
            "second": { "type": "command", "command": "b" }
          }
        }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        try CmuxConfigActionSaver.deleteAction(id: "first", globalConfigPath: configPath)

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
        #expect(Array(config.actions.keys) == ["second"])
    }

    @Test func deleteLastActionRemovesSeparatorComma() throws {
        let root = try temporaryRoot("delete-last")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("cmux.json").path
        try """
        {
          "actions": {
            "first": { "type": "command", "command": "https://example.com" }, // url note
            "last": { "type": "command", "command": "b" }
          }
        }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        try CmuxConfigActionSaver.deleteAction(id: "last", globalConfigPath: configPath)

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.contains("// url note"))
        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
        #expect(Array(config.actions.keys) == ["first"])
    }

    @Test func deleteSoleActionLeavesEmptyObject() throws {
        let root = try temporaryRoot("delete-sole")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("cmux.json").path
        try """
        {
          "actions": {
            "only": { "type": "command", "command": "a" }
          }
        }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        try CmuxConfigActionSaver.deleteAction(id: "only", globalConfigPath: configPath)

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
        #expect(config.actions.isEmpty)
    }

    @Test func deleteMissingActionThrowsAndPreservesFile() throws {
        let root = try temporaryRoot("delete-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("cmux.json").path
        let original = "{\n  \"actions\": {}\n}\n"
        try original.write(toFile: configPath, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try CmuxConfigActionSaver.deleteAction(id: "ghost", globalConfigPath: configPath)
        }
        #expect(try String(contentsOfFile: configPath, encoding: .utf8) == original)
    }

    // MARK: - Foreground command capture

    @Test func commandLinePreservesInvocationFormAndQuotes() {
        #expect(TerminalForegroundCommandCapture.commandLine(fromArgv: ["htop"]) == "htop")
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: ["./gradlew", "test"]) == "./gradlew test"
        )
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: ["/usr/bin/npm", "run", "dev server"])
                == "/usr/bin/npm run 'dev server'"
        )
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: ["/Apps/My Tool.app/Contents/MacOS/my tool", "--flag"])
                == "'/Apps/My Tool.app/Contents/MacOS/my tool' --flag"
        )
        #expect(TerminalForegroundCommandCapture.commandLine(fromArgv: ["-zsh"]) == nil)
        #expect(TerminalForegroundCommandCapture.commandLine(fromArgv: ["/bin/zsh"]) == nil)
        #expect(TerminalForegroundCommandCapture.commandLine(fromArgv: []) == nil)
    }

    @Test func commandLineStripsAgentResumeArtifacts() {
        // Agent detection works on the basename; the invocation form is kept.
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: [
                "/opt/homebrew/bin/claude", "--resume", "abc-123", "--dangerously-skip-permissions",
            ]) == "/opt/homebrew/bin/claude --dangerously-skip-permissions"
        )
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: [
                "codex", "resume", "0199d9c1", "--yolo",
            ]) == "codex --yolo"
        )
        // Unknown executables keep their flags untouched.
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: [
                "mytool", "--resume", "state.bin",
            ]) == "mytool --resume state.bin"
        )
        // Alias basenames sanitize through their real agent kind.
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: [
                "agy", "--continue", "old-conversation", "--sandbox", "danger-full-access",
            ]) == "agy --sandbox danger-full-access"
        )
    }

    @Test func commandLineUnwrapsNodeCodexAndStripsCmuxHooks() {
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: nodeWrappedCodexHookArgv()) ==
                "codex --dangerously-bypass-approvals-and-sandbox --model gpt-5.5 -c model_reasoning_effort=xhigh"
        )
    }

    @Test func commandLineKeepsClaudeDirectBinaryBehavior() {
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: [
                "/Users/u/.local/bin/claude",
                "--dangerously-skip-permissions",
                "--model",
                "claude-fable-5",
                "--effort",
                "high",
            ]) == "/Users/u/.local/bin/claude --dangerously-skip-permissions --model claude-fable-5 --effort high"
        )
    }

    @Test func knownAgentKindCoversAliasesAndArchSuffixedBuilds() {
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "claude") == "claude")
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "agy") == "antigravity")
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "cursor-agent") == "cursor")
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "grok-macos-aarch64") == "grok")
        // Registry-owned kinds are omitted from allCases but must still match.
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "pi") == "pi")
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "grok") == "grok")
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "antigravity") == "antigravity")
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "mytool") == nil)
    }

    @Test func snapshotDisclosuresListEveryPersistedCommandURLAndEnvKey() {
        let snapshot = WorkspaceConfigActionSnapshot(
            definition: CmuxWorkspaceDefinition(
                name: "W",
                env: ["API_TOKEN": "secret"],
                layout: .split(CmuxSplitDefinition(
                    direction: .horizontal,
                    split: 0.5,
                    children: [
                        .pane(CmuxPaneDefinition(surfaces: [
                            CmuxSurfaceDefinition(type: .terminal, command: "claude", env: ["RUST_LOG": "debug"])
                        ])),
                        .pane(CmuxPaneDefinition(surfaces: [
                            CmuxSurfaceDefinition(type: .browser, url: "https://example.com/callback?code=abc"),
                            CmuxSurfaceDefinition(type: .terminal, command: "curl -H 'Authorization: Bearer x'"),
                        ])),
                    ]
                ))
            ),
            skippedPanelCount: 0
        )
        #expect(snapshot.capturedCommands == ["claude", "curl -H 'Authorization: Bearer x'"])
        #expect(snapshot.capturedURLs == ["https://example.com/callback?code=abc"])
        #expect(snapshot.capturedEnvironmentKeys == ["API_TOKEN", "RUST_LOG"])

        let plain = WorkspaceConfigActionSnapshot(
            definition: CmuxWorkspaceDefinition(name: "P"),
            skippedPanelCount: 0
        )
        #expect(plain.capturedCommands == [])
        #expect(plain.capturedURLs == [])
        #expect(plain.capturedEnvironmentKeys == [])
    }

    @Test func snapshotReportsOversizedCommands() {
        let exactLimit = String(repeating: "a", count: TerminalForegroundCommandCapture.maxReplayableCommandUTF8Length)
        let oversized = exactLimit + "b"
        let snapshot = WorkspaceConfigActionSnapshot(
            definition: CmuxWorkspaceDefinition(
                name: "W",
                setup: oversized,
                layout: .pane(CmuxPaneDefinition(surfaces: [
                    CmuxSurfaceDefinition(type: .terminal, command: exactLimit),
                    CmuxSurfaceDefinition(type: .terminal, command: oversized),
                ]))
            ),
            skippedPanelCount: 0
        )
        #expect(snapshot.oversizedCommands == [oversized, oversized])
    }

    private func nodeWrappedCodexHookArgv() -> [String] {
        [
            "node",
            "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex",
            "--enable",
            "hooks",
            "--dangerously-bypass-hook-trust",
            "-c",
            "hooks.SessionStart=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-session-start.sh''',timeout=10000}]}]",
            "-c",
            "hooks.UserPromptSubmit=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-user-prompt-submit.sh''',timeout=10000}]}]",
            "-c",
            "hooks.PreToolUse=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-pre-tool-use.sh''',timeout=10000}]}]",
            "-c",
            "hooks.PostToolUse=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-post-tool-use.sh''',timeout=10000}]}]",
            "-c",
            "hooks.Notification=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-notification.sh''',timeout=10000}]}]",
            "-c",
            "hooks.Stop=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-stop.sh''',timeout=10000}]}]",
            "--dangerously-bypass-approvals-and-sandbox",
            "--model",
            "gpt-5.5",
            "-c",
            "model_reasoning_effort=xhigh",
        ]
    }
}
