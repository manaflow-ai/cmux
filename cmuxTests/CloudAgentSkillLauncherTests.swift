import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#else
    @testable import cmux
#endif

@Suite struct CloudAgentSkillLauncherTests {
    @Test func bundledSkillResourceExistsAndMentionsTheCLI() {
        let markdown = CloudAgentSkillLauncher.skillMarkdown()
        #expect(markdown != nil, "Resources/cloud-agent-skill.md must ship in the app bundle")
        #expect(markdown?.contains("cmux vm") == true)
        #expect(markdown?.contains("--help` is authoritative") == true)
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
        #expect(contents.contains("cmux vm"))

        // Regeneration overwrites in place rather than failing.
        _ = try CloudAgentSkillLauncher.installSkillFile(homeDirectory: home)
    }
}
