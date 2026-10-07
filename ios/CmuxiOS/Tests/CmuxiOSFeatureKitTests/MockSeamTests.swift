import CmuxiOSFeatureKit
import Foundation
import Testing

@Suite struct MockSeamTests {
    @Test func feedReplyResolvesOnceThenRefuses() async throws {
        let feed = MockFeedSource()
        let allow = FeedReply.permission(allow: true, scope: .session)
        let first = try await feed.perform(.answer(itemID: "feed1", reply: allow), key: IntentKey())
        guard case .committed = first else { Issue.record("expected commit, got \(first)"); return }
        let second = try await feed.perform(.answer(itemID: "feed1", reply: .permission(allow: false, scope: nil)), key: IntentKey())
        guard case .refused = second else { Issue.record("expected refusal, got \(second)"); return }
        let item = await feed.hub.current.value.first { $0.id == "feed1" }
        #expect(item?.state == .answered)
        #expect(item?.answer?.reply == allow)
        #expect(item?.isRead == true)
    }

    @Test func feedRefusesArchivingAnOpenRequestAndMismatchedReplies() async throws {
        let feed = MockFeedSource()
        let archive = try await feed.perform(.archive(itemIDs: ["feed1"]), key: IntentKey())
        guard case .refused = archive else { Issue.record("expected refusal, got \(archive)"); return }
        let wrongShape = try await feed.perform(.answer(itemID: "feed1", reply: .text("yes")), key: IntentKey())
        guard case .refused = wrongShape else { Issue.record("expected refusal, got \(wrongShape)"); return }
        let revision = await feed.hub.current.revision
        #expect(revision == 1)
    }

    @Test func workspaceIntentsOnUnreachableHostAreRefused() async throws {
        let source = MockWorkspaceSource()
        let receipt = try await source.perform(.rename(workspaceID: "ws_mini1", title: "x"), key: IntentKey())
        guard case .refused = receipt else { Issue.record("expected refusal, got \(receipt)"); return }
        let created = try await source.perform(.create(hostID: MockFixtures.studio, title: "new"), key: IntentKey())
        guard case .committed = created else { Issue.record("expected commit, got \(created)"); return }
        let titles = await source.hub.current.value.first?.workspaces.map(\.title)
        #expect(titles?.contains("new") == true)
    }

    @Test func composerRefusesEmptyPromptAndUnreachableHost() async throws {
        let sink = MockTaskComposerSink()
        let empty = try await sink.dispatch(TaskDraft(hostID: MockFixtures.studio, agentID: "claude", prompt: " "), key: IntentKey())
        guard case .refused = empty else { Issue.record("expected refusal"); return }
        let asleep = try await sink.dispatch(TaskDraft(hostID: MockFixtures.mini, agentID: "claude", prompt: "go"), key: IntentKey())
        guard case .refused = asleep else { Issue.record("expected refusal"); return }
        let key = IntentKey()
        let started = try await sink.dispatch(
            TaskDraft(hostID: MockFixtures.studio, workspaceID: "ws_studio1", agentID: "codex", prompt: "go"), key: key)
        #expect(started == .started(key: key, workspaceID: "ws_studio1"))
    }

    @Test func pairedMacsAreReadOnlyInHostsStore() async throws {
        let store = MockHostsStore()
        let receipt = try await store.remove(MockFixtures.studio, key: IntentKey())
        guard case .refused = receipt else { Issue.record("expected refusal"); return }
        let added = try await store.add(
            HostDraft(name: "lan", kind: .direct(endpoint: HostEndpoint(address: "192.168.1.5"),
                                                 hostKey: DirectHostKey(rawValue: String(repeating: "A", count: 43) + "=")!)),
            key: IntentKey())
        guard case .committed = added else { Issue.record("expected commit"); return }
        #expect(await store.hub.current.value.count == 4)
    }

    @Test func deviceRegistryPairsDiscoveredAndProtectsThisDevice() async throws {
        let registry = MockDeviceRegistry()
        let paired = try await registry.pair(PairingTicket(payload: Data()), key: IntentKey())
        guard case .committed = paired else { Issue.record("expected commit"); return }
        let self_ = try await registry.revoke("dev-phone", key: IntentKey())
        guard case .refused = self_ else { Issue.record("expected refusal"); return }
        let devices = await registry.hub.current.value
        #expect(devices.allSatisfy { $0.trust == .trusted })
    }

    @Test func fileTransferFinishesAndResumesAfterFailure() async throws {
        let transfer = MockFileTransfer(failAfterChunks: 3)
        let request = TransferRequest(hostID: MockFixtures.studio, direction: .upload(localURL: URL(fileURLWithPath: "/tmp/a")),
                                      remotePath: "~/a", byteCount: 800)
        var last: TransferProgress?
        for await progress in try await transfer.start(request) { last = progress }
        #expect(last?.state == .failed(reason: "Connection lost"))
        #expect(last?.completedBytes == 300)
        for await progress in try await transfer.resume(request.id) { last = progress }
        #expect(last?.state == .finished)
        #expect(last?.completedBytes == 800)
    }

    @Test func browserSessionEndsOnClose() async throws {
        let source = MockBrowserStreamSource()
        let session = try await source.open("tab_web1", on: MockFixtures.studio)
        var states: [BrowserStreamState] = []
        let stream = await session.states()
        await session.close()
        for await state in stream { states.append(state) }
        #expect(states.last == .ended(reason: nil))
    }

    @Test func realFactoriesFallBackToMockUntilRegistered() {
        var factories = RealFeatureFactories()
        let modes = Dictionary(uniqueKeysWithValues: FeatureSeam.allCases.map { ($0, FeatureSourceMode.real) })
        #expect(factories.resolve(modes).resolved.values.allSatisfy { $0 == .mock })
        factories.feed = { MockFeedSource() }
        let sources = factories.resolve(modes)
        #expect(sources.resolved[.feed] == .real)
        #expect(sources.resolved[.hosts] == .mock)
    }
}
