import CmuxiOSComposerCore
import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
import CmuxMobileWire
import Testing

@Suite("control-plane composer sink")
struct SinkTests {
    static let studio = MockFixtures.studio

    func next<T: Sendable>(_ iterator: inout AsyncStream<T>.Iterator, until predicate: (T) -> Bool) async -> T? {
        while let value = await iterator.next() {
            if predicate(value) { return value }
        }
        return nil
    }

    @Test func catalogCarriesEachMacsAdvertisedAgentsAndDispatchCap() async throws {
        let channels = FakeTaskChannels()
        let sink = ControlPlaneTaskComposerSink(workspaces: MockWorkspaceSource(), channels: channels)
        var catalogs = await sink.catalog().makeAsyncIterator()
        let empty = await next(&catalogs) { !$0.value.hosts.isEmpty }
        #expect(empty?.value.agents(on: Self.studio).isEmpty == true)
        let channel = try #require(channels.channel(Self.studio))
        await channel.push(.snapshot(TaskFrames.snapshot(seq: 1)))
        let loaded = await next(&catalogs) { !$0.value.agents(on: Self.studio).isEmpty }
        #expect(loaded?.value.agents(on: Self.studio).map(\.id) == ["claude", "codex"])
        #expect(loaded?.value.acceptsDispatch(Self.studio) == true)
        await channel.setState(.live(path: "relay", caps: ["task.stream"]))
        let gated = await next(&catalogs) { $0.value.acceptsDispatch(Self.studio) == false }
        #expect(gated != nil)
    }

    @Test func dispatchSubmitsOneOpAndReturnsTheReceipt() async throws {
        let channels = FakeTaskChannels()
        let sink = ControlPlaneTaskComposerSink(workspaces: MockWorkspaceSource(), channels: channels)
        var catalogs = await sink.catalog().makeAsyncIterator()
        _ = await next(&catalogs) { $0.value.acceptsDispatch(Self.studio) }
        let channel = try #require(channels.channel(Self.studio))
        await channel.setAnswer { op in
            .applied(ResultFrame(tx: "tx_1", idempotencyKey: op.idempotencyKey,
                                 value: .object(["task": "task_k1", "workspace": "ws_studio1", "tab": "tab_a1"]),
                                 revision: "2", replayed: false))
        }
        let key = IntentKey()
        let receipt = try await sink.dispatch(TaskDraft(hostID: Self.studio, workspaceID: "ws_studio1", agentID: "claude",
                                                        prompt: "Fix the sizing tests"), key: key)
        #expect(receipt == .started(key: key, workspaceID: "ws_studio1", taskID: "task_k1", tabID: "tab_a1"))
        let submitted = await channel.submitted
        #expect(submitted.count == 1)
        #expect(submitted.first?.idempotencyKey == key.rawValue)
        #expect(submitted.first?.params["prompt"] == "Fix the sizing tests")
    }

    @Test func refusalOfflineAndUnsupportedNeverQueue() async throws {
        let channels = FakeTaskChannels()
        let sink = ControlPlaneTaskComposerSink(workspaces: MockWorkspaceSource(), channels: channels)
        var catalogs = await sink.catalog().makeAsyncIterator()
        _ = await next(&catalogs) { $0.value.acceptsDispatch(Self.studio) }
        let channel = try #require(channels.channel(Self.studio))
        await channel.setAnswer { op in
            .rejected(RejectFrame(tx: "tx_1", idempotencyKey: op.idempotencyKey, code: "task.agent_unavailable",
                                  message: "Codex: Not signed in", retryable: false, replayed: false))
        }
        let draft = TaskDraft(hostID: Self.studio, agentID: "codex", prompt: "go")
        let key = IntentKey()
        #expect(try await sink.dispatch(draft, key: key) == .refused(key: key, reason: "Codex: Not signed in"))

        // Outcome unknown (socket lost): offline, so the caller keeps the key.
        await channel.setAnswer { _ in throw WorkspaceChannelError.outcomeUnknown }
        await #expect(throws: FeatureSourceError.offline) { try await sink.dispatch(draft, key: IntentKey()) }

        await channel.setState(.live(path: "relay", caps: []))
        _ = await next(&catalogs) { !$0.value.acceptsDispatch(Self.studio) }
        await #expect(throws: FeatureSourceError.unsupported("task.dispatch")) { try await sink.dispatch(draft, key: IntentKey()) }

        await channel.setState(.offline(reason: "Asleep"))
        _ = await next(&catalogs) { _ in true }
        await #expect(throws: FeatureSourceError.offline) { try await sink.dispatch(draft, key: IntentKey()) }
        #expect(await channel.submitted.count == 2)
    }

    @Test func taskStreamFollowsStateEventsAndRepairsGaps() async throws {
        let channels = FakeTaskChannels()
        let sink = ControlPlaneTaskComposerSink(workspaces: MockWorkspaceSource(), channels: channels)
        var tasks = await sink.tasks(on: Self.studio).makeAsyncIterator()
        var catalogs = await sink.catalog().makeAsyncIterator()
        _ = await next(&catalogs) { !$0.value.hosts.isEmpty }
        let channel = try #require(channels.channel(Self.studio))
        await channel.push(.snapshot(TaskFrames.snapshot(seq: 5, tasks: [TaskFrames.task("task_k1")])))
        let first = await next(&tasks) { !$0.value.isEmpty }
        #expect(first?.value.first?.state == .queued)
        await channel.push(.event(TaskFrames.state(seq: 6, task: "task_k1", state: "running")))
        let running = await next(&tasks) { $0.value.first?.state == .running }
        #expect(running?.connection.isLive == true)
        await channel.push(.event(TaskFrames.state(seq: 9, task: "task_k1", state: "done")))
        await channel.push(.snapshot(TaskFrames.snapshot(seq: 9, tasks: [TaskFrames.task("task_k1", state: "done")])))
        let done = await next(&tasks) { $0.value.first?.state == .done }
        #expect(done != nil)
        #expect(await channel.snapshotRequests == 1)
    }

    @Test func channelsCloseWhenTheLastSubscriberLeaves() async throws {
        let channels = FakeTaskChannels()
        let sink = ControlPlaneTaskComposerSink(workspaces: MockWorkspaceSource(), channels: channels)
        let catalog = Task { for await _ in await sink.catalog() {} }
        let tasks = Task { for await _ in await sink.tasks(on: Self.studio) {} }
        var channel: FakeTaskChannel?
        for _ in 0..<1000 where channel == nil {
            await Task.yield()
            channel = channels.channel(Self.studio)
        }
        let opened = try #require(channel)
        catalog.cancel()
        await Task.yield()
        #expect(await opened.closed == false)
        tasks.cancel()
        var closed = false
        for _ in 0..<1000 where !closed {
            await Task.yield()
            closed = await opened.closed
        }
        #expect(closed)
    }
}
