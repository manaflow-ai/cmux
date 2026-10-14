import CmuxConversationCore
import CnxModel
import Foundation
import Testing
#if os(iOS)
import SwiftUI
#endif
@testable import CnxChief

/// The Home and Chief design pass (verify/design/home-chief/SPEC.md).
@Suite struct ChiefEngineReportDesignTests {
    private func report(_ result: String) throws -> ChiefEngineReport {
        let line = #"{"protocol":"cmux.protocol/2","type":"response","id":"r1","ok":true,"result":"# + result + "}"
        return try ChiefControl.decode(Data(line.utf8), mutation: false)
    }

    /// SPEC 2: the Mac's avatar text when its reply has one; today's Macs
    /// send no `avatar` key, so the phone keeps "C" and offers no Avatar row.
    @Test func avatarComesFromTheMacWhenItSendsOne() throws {
        let today = try report(#"{"engine":{"harness":"codex"}}"#)
        #expect(!today.avatarSupported)
        #expect(today.avatar == nil)
        let set = try report(#"{"engine":{"harness":"codex"},"avatar":"🦊"}"#)
        #expect(set.avatarSupported)
        #expect(set.avatar == "🦊")
        let empty = try report(#"{"engine":{"harness":"codex"},"avatar":null}"#)
        #expect(empty.avatarSupported)
        #expect(empty.avatar == nil)
        // A picture's file name is not avatar text.
        #expect(try report(#"{"engine":{},"avatar":"cat.png"}"#).avatar == nil)
        #expect(ChiefEngineReport.avatarText("  AB  ") == "AB")
        #expect(ChiefEngineReport.avatarText("ABC") == "AB")
    }

    /// SPEC 4: acpmux's "default" model entry names what it resolves to and
    /// is not listed twice.
    @Test func defaultModelEntryIsSeparate() throws {
        let got = try report(#"{"engine":{"harness":"codex"},"offered":{"models":[{"id":"default","name":"Default (GPT-6.1 Sol)"},{"id":"gpt-6.1-sol","name":"GPT-6.1 Sol"}]}}"#)
        #expect(got.defaultModel?.name == "Default (GPT-6.1 Sol)")
        #expect(got.pickableModels.map(\.id) == ["gpt-6.1-sol"])
        #expect(got.modelName("gpt-6.1-sol") == "GPT-6.1 Sol")
        #expect(got.modelName("default") == nil)
        #expect(got.modelName(nil) == nil)
    }
}

@Suite struct ChiefAvatarIdentityTests {
    /// SPEC 2: Chief's header avatar is its avatar text, not initials of its name.
    @Test func chiefParticipantUsesAvatarText() {
        let identity = ChiefIdentity(avatar: "🦊")
        #expect(identity.chief.initials == "🦊")
        let wire = ChiefWire(identity: identity)
        let info = wire.info(["id": "c1", "participants": [
            ["id": "user_local", "display_name": "You"],
            ["id": "agent_mux", "display_name": "Chief Of Staff"],
        ]])
        #expect(info?.participants.first { $0.id == "agent_mux" }?.initials == "🦊")
        #expect(ChiefIdentity.standard.chief.initials == "C")
    }

    #if DEBUG
    /// SPEC 7: every seeded reply is later than the message it answers.
    @Test func mockSeedIsInOrder() {
        let messages = ChiefMockScript.history(identity: .standard, now: Date())
        #expect(zip(messages, messages.dropFirst()).allSatisfy { $0.sentAt < $1.sentAt })
    }
    #endif
}

@Suite @MainActor struct ChiefSessionHomeStateTests {
    /// SPEC 1.6: Needs You and the pin's preview follow the outbox.
    @Test func outboxMeansChiefWaitsOnYou() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
        let session = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: file))
        #expect(!session.needsYou)
        #expect(!session.isWaitingOnYou)
        session.send(ConversationComposeMessage(text: "status?"))
        #expect(session.needsYou)
        #expect(session.isWaitingOnYou)
        session.discardOutbox()
        #expect(!session.needsYou)
        #expect(session.avatar == "C")
    }
}

#if os(iOS)
@Suite @MainActor struct HomeDesignTests {
    private func tab(_ id: String, _ title: String) -> WorkspaceTab {
        WorkspaceTab(id: id, kind: .agent, title: title, subtitle: nil, harness: title.lowercased())
    }

    /// SPEC 1.2: rows read by workspace; a second agent tab adds the agent.
    @Test func rowTitlesAreTheWorkspace() {
        let ids = ["a", "b"]
        #expect(ConversationsHome<EmptyToolbar>.title(of: tab("a", "Claude"), in: "cmux", agentIDs: ids) == "cmux")
        #expect(ConversationsHome<EmptyToolbar>.title(of: tab("b", "Codex"), in: "cmux", agentIDs: ids) == "cmux · Codex")
    }

    /// SPEC 4: recent turns read as words, never raw ids.
    @Test func recentTurnsAreReadable() {
        let report = ChiefEngineReport(engine: .init(harness: "codex"),
                                       offered: .init(models: [.init(id: "opus", name: "Claude Opus")]))
        var turn = ChiefEngineReport.Turn()
        turn.harness = "claude"
        turn.status = "error"
        turn.ms = 177_000
        turn.tools = 3
        turn.costUSD = 0.04
        #expect(ChiefSettingsView.turnTitle(turn, in: report) == "Claude")
        turn.model = "opus"
        #expect(ChiefSettingsView.turnTitle(turn, in: report) == "Claude Opus")
        #expect(ChiefSettingsView.turnLine(turn) == "Failed · 2 min 57 s · 3 tools · $0.04")
        #expect(ChiefSettingsView.durationText(milliseconds: 45_000) == "45 s")
    }

    /// SPEC 4: the default model item names the model it resolves to.
    @Test func defaultModelLabelNamesTheModel() {
        let fromEntry = ChiefEngineReport(engine: .init(harness: "codex"),
                                          offered: .init(models: [.init(id: "default", name: "Default (GPT-6.1 Sol)")]))
        #expect(ChiefSettingsView.defaultModelLabel(fromEntry) == "Default (GPT-6.1 Sol)")
        let named = ChiefEngineReport(engine: .init(harness: "codex"),
                                      offered: .init(models: [.init(id: "default", name: "GPT-6.1 Sol")]))
        #expect(ChiefSettingsView.defaultModelLabel(named) == "Default (GPT-6.1 Sol)")
        let resolved = ChiefEngineReport(engine: .init(harness: "claude", model: "opus"),
                                         offered: .init(models: [.init(id: "opus", name: "Claude Opus")]))
        #expect(ChiefSettingsView.defaultModelLabel(resolved) == "Default (Claude Opus)")
        #expect(ChiefSettingsView.defaultModelLabel(ChiefEngineReport(engine: .init(harness: "codex"))) == "Default")
    }
}

struct EmptyToolbar: ToolbarContent {
    var body: some ToolbarContent { ToolbarItem { EmptyView() } }
}
#endif
