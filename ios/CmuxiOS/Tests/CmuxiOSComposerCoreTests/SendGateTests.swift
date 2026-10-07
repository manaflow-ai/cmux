import CmuxiOSComposerCore
import CmuxiOSFeatureKit
import Testing

@Suite("send gate")
struct SendGateTests {
    let catalog = ComposerCatalog(hosts: MockFixtures.hostWorkspaces(), agents: MockFixtures.agents)

    func draft(_ host: HostID = MockFixtures.studio, agent: String? = "claude", prompt: String = "go",
               attachments: [ComposerAttachment] = []) -> ComposerDraft {
        ComposerDraft(target: ComposerTarget(hostID: host), agentID: agent, model: "opus", effort: "medium",
                      prompt: prompt, attachments: attachments)
    }

    func blocker(_ draft: ComposerDraft, catalog: ComposerCatalog? = nil, connection: SourceConnection = .live(path: nil),
                 sending: Bool = false) -> ComposerSendBlocker? {
        ComposerSendGate(draft: draft, catalog: catalog ?? self.catalog, connection: connection, isSending: sending).blocker
    }

    @Test func aCompleteDraftCanGo() {
        #expect(blocker(draft()) == nil)
    }

    @Test func reasonsInTheOrderAUserFixesThem() {
        #expect(blocker(draft(), sending: true) == .sending)
        #expect(blocker(draft(), connection: .offline(reason: "No network")) == .offline(reason: "No network"))
        #expect(blocker(draft(HostID("h_unknown"))) == .noTarget)
        guard case .hostUnreachable = blocker(draft(MockFixtures.mini)) else {
            Issue.record("an asleep Mac blocks sending")
            return
        }
        #expect(blocker(draft(agent: nil)) == .noAgent)
        #expect(blocker(draft(agent: "opencode")) == .agentUnavailable(name: "OpenCode", reason: "Not installed"))
        #expect(blocker(draft(prompt: " \n ")) == .emptyPrompt)
    }

    @Test func dispatchNeedsTheMacsCap() {
        var gated = catalog
        gated.dispatchHosts = []
        #expect(blocker(draft(), catalog: gated) == .dispatchUnsupported)
        gated.dispatchHosts = [MockFixtures.studio]
        gated.agentsByHost = [MockFixtures.studio: []]
        #expect(blocker(draft(), catalog: gated) == .noAgents)
    }

    @Test func attachmentsMustFinishUploading() {
        let uploading = ComposerAttachment(id: TransferID(), name: "a.png", mime: "image/png", byteCount: 10)
        #expect(blocker(draft(attachments: [uploading])) == .uploadsPending)
        var failed = uploading
        failed.phase = .failed
        #expect(blocker(draft(attachments: [failed])) == .uploadFailed)
        var ready = uploading
        ready.phase = .ready
        ready.uploadID = "up_ab12"
        #expect(blocker(draft(attachments: [ready])) == nil)
        #expect(draft(attachments: [ready]).taskDraft()?.uploads == ["up_ab12"])
    }
}
