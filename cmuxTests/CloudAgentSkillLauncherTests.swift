import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#else
    @testable import cmux
#endif

@Suite struct CloudAgentSkillLauncherTests {
    @Test func bundledSkillResourceExistsAndMentionsTheCLI() throws {
        let markdown = try #require(
            CloudAgentSkillLauncher.skillMarkdown(),
            "Resources/cloud-agent-skill.md must ship in the app bundle"
        )
        #expect(markdown.contains("cmux vm --help"))
        #expect(markdown.contains("cmux vm ls"))
    }

    @Test func kickoffPromptReferencesTheSkillPathAndDiscovery() {
        let prompt = CloudAgentSkillLauncher.kickoffPrompt(skillPath: "/tmp/skill.md")
        #expect(prompt.contains("/tmp/skill.md"))
        #expect(prompt.contains("cmux vm ls"))
        #expect(prompt.contains("--help"))
    }

    @Test func agentArgvShapes() {
        #expect(CloudAgentSkillLauncher.CodingAgent.claude.argv(prompt: "p") == ["claude", "p"])
        #expect(CloudAgentSkillLauncher.CodingAgent.codex.argv(prompt: "p") == ["codex", "p"])
        #expect(
            CloudAgentSkillLauncher.CodingAgent.opencode.argv(prompt: "p")
                == ["opencode", "--prompt", "p"]
        )
    }

    @Test func installSkillFileWritesUnderTheGivenHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-agent-skill-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let url = try CloudAgentSkillLauncher.installSkillFile(homeDirectory: home)
        #expect(
            url.path
                == home.appendingPathComponent(CloudAgentSkillLauncher.installedSkillRelativePath).path
        )
        let contents = try String(contentsOf: url, encoding: .utf8)
        let bundledContents = try #require(CloudAgentSkillLauncher.skillMarkdown())
        #expect(contents == bundledContents)
        #expect(contents.contains("cmux vm --help"))

        // Regeneration overwrites in place rather than failing.
        try "stale skill".write(to: url, atomically: true, encoding: .utf8)
        _ = try CloudAgentSkillLauncher.installSkillFile(homeDirectory: home)
        #expect(try String(contentsOf: url, encoding: .utf8) == bundledContents)
    }
}
