import XCTest

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#else
    @testable import cmux
#endif

final class CloudAgentSkillLauncherTests: XCTestCase {
    func testBundledSkillResourceExistsAndMentionsTheCLI() {
        let markdown = CloudAgentSkillLauncher.skillMarkdown()
        XCTAssertNotNil(markdown, "Resources/cloud-agent-skill.md must ship in the app bundle")
        XCTAssertTrue(markdown?.contains("cmux vm") == true)
        XCTAssertTrue(markdown?.contains("--help` is authoritative") == true)
    }

    func testKickoffPromptReferencesTheSkillPathAndDiscovery() {
        let prompt = CloudAgentSkillLauncher.kickoffPrompt(skillPath: "/tmp/skill.md")
        XCTAssertTrue(prompt.contains("/tmp/skill.md"))
        XCTAssertTrue(prompt.contains("cmux vm ls"))
        XCTAssertTrue(prompt.contains("--help"))
    }

    func testAgentArgvShapes() {
        XCTAssertEqual(
            CloudAgentSkillLauncher.CodingAgent.claude.argv(prompt: "p"),
            ["claude", "p"]
        )
        XCTAssertEqual(
            CloudAgentSkillLauncher.CodingAgent.codex.argv(prompt: "p"),
            ["codex", "p"]
        )
        XCTAssertEqual(
            CloudAgentSkillLauncher.CodingAgent.opencode.argv(prompt: "p"),
            ["opencode", "--prompt", "p"]
        )
    }

    func testShellCommandQuotesThePrompt() {
        let command = CloudAgentSkillLauncher.shellCommand(
            agent: .claude,
            prompt: "read the file; it's important"
        )
        XCTAssertEqual(command, "claude 'read the file; it'\\''s important'")
    }

    func testInstallSkillFileWritesUnderTheGivenHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-agent-skill-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let url = try CloudAgentSkillLauncher.installSkillFile(homeDirectory: home)
        XCTAssertEqual(
            url.path,
            home.appendingPathComponent(CloudAgentSkillLauncher.installedSkillRelativePath).path
        )
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("cmux vm"))

        // Regeneration overwrites in place rather than failing.
        _ = try CloudAgentSkillLauncher.installSkillFile(homeDirectory: home)
    }
}
