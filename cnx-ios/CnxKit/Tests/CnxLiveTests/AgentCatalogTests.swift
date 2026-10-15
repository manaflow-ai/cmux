import CnxAgentChat
import CnxModel
import Foundation
import Testing
@testable import CnxLive

/// The phone's New Agent Chat mirrors the Mac's: one model-agnostic entry on the Mac's default
/// agent, every other agent listed with why a phone can't start it.
@Suite struct AgentCatalogTests {
    func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// A `_acpmux/harnesses` reply shaped like acpmux's `harnesses_view` (harnesses keyed by id).
    var harnesses: String {
        """
        {"defaultHarness": "codex",
         "harnesses": {
           "codex": {"argv": ["codex-acp"], "family": "codex"},
           "claude": {"argv": ["claude-agent-acp"], "family": "claude", "start": {"model": "opus", "modelSource": "harness"}},
           "claude-cr": {"argv": ["claude-agent-acp"], "family": "claude", "displayName": "Claude (CodeRouter)"},
           "gemini": {"argv": ["gemini", "--acp"], "family": "gemini", "unavailable": "gemini is not installed"},
           "pi": {"argv": ["pi"], "family": "pi", "probeError": "probe timed out"},
           "muse": {"argv": ["muse"], "kind": "terminal"}
         }}
        """
    }

    var models: String {
        """
        {"harnesses": [
          {"harness": "claude", "isDefault": false, "models": [
            {"id": "default", "name": "default (agent's choice)"},
            {"id": "opus", "name": "Opus"},
            {"id": "sonnet", "name": "Sonnet"},
            {"id": "haiku", "name": "Haiku", "unavailable": "your plan does not include this model"}]}
        ]}
        """
    }

    @Test func theMacsDefaultIsSkippedWhenAPhoneCantStartIt() throws {
        let catalog = AgentCatalog(harnesses: try json(harnesses), models: try json(models))
        // Codex is the Mac's default, but a phone never starts it: Claude stands in.
        #expect(catalog.harness("codex")?.isDefault == true)
        #expect(catalog.harness("codex")?.unavailableReason == "Not available from here: this agent has no mode that asks before each change")
        #expect(catalog.defaultChoice?.id == "claude")
        // The Mac's default first in the list, then by name.
        #expect(catalog.harnesses.first?.id == "codex")
    }

    @Test func aStartableDefaultIsUsed() throws {
        var reply = try json(harnesses)
        if case .object(var object) = reply {
            object["defaultHarness"] = .string("claude-cr")
            reply = .object(object)
        }
        #expect(AgentCatalog(harnesses: reply).defaultChoice?.id == "claude-cr")
    }

    @Test func launchersAndTerminalHarnesses() throws {
        let catalog = AgentCatalog(harnesses: try json(harnesses), models: try json(models))
        // A terminal harness runs in a terminal tab, not as a chat.
        #expect(catalog.harness("muse") == nil)
        // A launcher that can't run is Unavailable with the Mac's reason; a failed probe alone is not.
        #expect(catalog.harness("gemini")?.unavailableReason == "gemini is not installed")
        #expect(catalog.harness("pi")?.canStart == true)
        #expect(catalog.harness("claude")?.name == "Claude Code")
        #expect(catalog.harness("claude-cr")?.name == "Claude (CodeRouter)")
    }

    @Test func modelsAndTheirDefault() throws {
        let catalog = AgentCatalog(harnesses: try json(harnesses), models: try json(models))
        let claude = try #require(catalog.harness("claude"))
        #expect(claude.defaultModel == "opus")
        #expect(claude.models.map(\.id) == ["default", "opus", "sonnet", "haiku"])
        #expect(claude.models.last?.unavailableReason == "your plan does not include this model")
        // The default model is no model change; another model is.
        #expect(catalog.resolve(.macDefault)?.harness.id == "claude")
        #expect(catalog.resolve(.macDefault)?.model == nil)
        #expect(catalog.resolve(AgentChatStart(harness: "claude", model: "opus"))?.model == nil)
        #expect(catalog.resolve(AgentChatStart(harness: "claude", model: "sonnet"))?.model == "sonnet")
        // A harness a phone can't start resolves to nothing (the toast says why).
        #expect(catalog.resolve(AgentChatStart(harness: "codex")) == nil)
        #expect(catalog.resolve(AgentChatStart(harness: "gemini")) == nil)
    }

    @Test func nothingStartable() throws {
        let only = try json(#"{"defaultHarness": "codex", "harnesses": {"codex": {"argv": ["codex-acp"]}, "opencode": {"argv": ["opencode", "acp"], "family": "opencode"}}}"#)
        let catalog = AgentCatalog(harnesses: only)
        #expect(catalog.defaultChoice == nil)
        #expect(catalog.unavailableReason == AgentCatalog.refusedReason)
        #expect(AgentCatalog(harnesses: try json(#"{"harnesses": {}}"#)).unavailableReason == "No agents are set up in cmux on this Mac.")
    }
}

/// New Workspace in a folder (Recent Directories): the new terminal changes to it as the
/// person would type; the phone never sends `cwd`. Agent chats never start in a home folder.
@Suite struct WorkspaceFolderTests {
    @Test func changeDirectoryLines() {
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("~/Development/cmux") == "cd ~/'Development/cmux' && clear\n")
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("/tmp/it's here") == "cd '/tmp/it'\\''s here' && clear\n")
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("~") == nil)
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("relative") == nil)
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("/x\nrm -rf ~") == nil)
    }

    @Test func homeAndAboveAreNoProject() {
        for path in ["/", "/Users", "/Users/aziz", "/Users/aziz/", "/var/root"] {
            #expect(LiveWorkspaceCreationBackend.isHomeOrAbove(path), "\(path)")
        }
        for path in ["/Users/aziz/Projects/mario", "/tmp/x", "/Volumes/work"] {
            #expect(!LiveWorkspaceCreationBackend.isHomeOrAbove(path), "\(path)")
        }
    }
}
