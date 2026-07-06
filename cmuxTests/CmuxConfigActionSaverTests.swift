import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// "Save Workspace as Action" persistence (JSONC upsert into cmux.json) and
/// the foreground-command capture that feeds saved terminal surfaces.
final class CmuxConfigActionSaverTests: XCTestCase {

    // MARK: - Slugs and ids

    func testSlugForTitle() {
        XCTAssertEqual(CmuxConfigActionSaver.slug(forTitle: "My Dev Setup!"), "my-dev-setup")
        XCTAssertEqual(CmuxConfigActionSaver.slug(forTitle: "  --  "), "workspace")
        XCTAssertEqual(CmuxConfigActionSaver.slug(forTitle: "日本語 Dev"), "日本語-dev")
    }

    func testUniqueActionID() {
        XCTAssertEqual(
            CmuxConfigActionSaver.uniqueActionID(forTitle: "Dev", existingIDs: []),
            "dev"
        )
        XCTAssertEqual(
            CmuxConfigActionSaver.uniqueActionID(forTitle: "Dev", existingIDs: ["dev", "dev-2"]),
            "dev-3"
        )
    }

    // MARK: - Saving

    func testSaveWorkspaceActionPreservesCommentsAndDecodes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-action-saver-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
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
        XCTAssertEqual(result.actionID, "dev-2", "id should be uniquified against the existing 'dev'")

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(saved.contains("// build actions"))
        XCTAssertTrue(saved.contains("// keep me"))

        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
        let inline = try XCTUnwrap(config.actions["dev-2"]?.action?.inlineWorkspace)
        XCTAssertEqual(inline.definition.name, "Dev")
        XCTAssertEqual(inline.definition.setup, "make deps")
        XCTAssertEqual(config.actions["dev-2"]?.title, "Dev")
        guard case .pane(let pane)? = inline.definition.layout else {
            return XCTFail("Expected pane layout")
        }
        XCTAssertEqual(pane.surfaces.first?.command, "claude")
    }

    func testSaveWorkspaceActionRespectsReservedIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-action-saver-reserved-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let configPath = root.appendingPathComponent("cmux.json").path

        let result = try CmuxConfigActionSaver.saveWorkspaceAction(
            title: "Dev",
            definition: CmuxWorkspaceDefinition(name: "Dev"),
            globalConfigPath: configPath,
            reservedActionIDs: ["dev"]
        )
        XCTAssertEqual(result.actionID, "dev-2", "id reserved by the active store must not be reused")
    }

    func testSaveWorkspaceActionCreatesFileFromTemplate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-action-saver-template-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let configPath = root.appendingPathComponent("nested/cmux.json").path

        let result = try CmuxConfigActionSaver.saveWorkspaceAction(
            title: "Fresh",
            definition: CmuxWorkspaceDefinition(name: "Fresh"),
            globalConfigPath: configPath
        )
        XCTAssertEqual(result.actionID, "fresh")

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(saved.contains("$schema"))
        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
        XCTAssertNotNil(config.actions["fresh"]?.action?.inlineWorkspace)
    }

    // MARK: - Foreground command capture

    func testCommandLineFromArgvQuotesAndBasenamesExecutable() {
        XCTAssertEqual(
            TerminalForegroundCommandCapture.commandLine(fromArgv: ["/usr/local/bin/htop"]),
            "htop"
        )
        XCTAssertEqual(
            TerminalForegroundCommandCapture.commandLine(fromArgv: ["/usr/bin/npm", "run", "dev server"]),
            "npm run 'dev server'"
        )
        XCTAssertNil(TerminalForegroundCommandCapture.commandLine(fromArgv: ["-zsh"]))
        XCTAssertNil(TerminalForegroundCommandCapture.commandLine(fromArgv: []))
    }

    func testCommandLineFromArgvStripsAgentResumeArtifacts() {
        XCTAssertEqual(
            TerminalForegroundCommandCapture.commandLine(fromArgv: [
                "/opt/homebrew/bin/claude", "--resume", "abc-123", "--dangerously-skip-permissions",
            ]),
            "claude --dangerously-skip-permissions"
        )
        XCTAssertEqual(
            TerminalForegroundCommandCapture.commandLine(fromArgv: [
                "codex", "resume", "0199d9c1", "--yolo",
            ]),
            "codex --yolo"
        )
        // Unknown executables keep their flags untouched.
        XCTAssertEqual(
            TerminalForegroundCommandCapture.commandLine(fromArgv: [
                "mytool", "--resume", "state.bin",
            ]),
            "mytool --resume state.bin"
        )
    }
}
