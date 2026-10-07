import CmuxiOSFeatureKit
import CmuxMobileWire
import CmuxiOSWorkspacesCore
import Foundation
import Testing

@Suite struct ControlPlaneSourceTests {
    let mac = HostID("h_mac1")
    let mini = HostID("h_mini")
    let wire = WireFrames(host: "h_mac1")
    let allCaps: Set<String> = ["workspace.close", "workspace.read", "workspace.preview",
                                "workspace.move", "workspace.group.rename", "workspace.customize"]

    func make(_ hosts: [HostID] = [HostID("h_mac1")]) -> (ControlPlaneWorkspaceSource, FakeChannelFactory, StaticHostDirectory) {
        let factory = FakeChannelFactory(hosts)
        let directory = StaticHostDirectory(hosts.map { WorkspaceHostDescriptor(id: $0, name: $0.rawValue) })
        return (ControlPlaneWorkspaceSource(directory: directory, channels: factory), factory, directory)
    }

    func titles(_ s: SourceSnapshot<[HostWorkspaces]>, _ host: HostID) -> [String] {
        s.value.first { $0.hostID == host }?.workspaces.map(\.title) ?? []
    }

    @Test func mirrorsSnapshotThenEvents() async throws {
        let (source, factory, _) = make()
        var waiter = SnapshotWaiter(await source.updates())
        let channel = factory[mac]
        await channel.waitForSubscriber()
        await channel.send(.live(path: "relay", caps: allCaps))
        await channel.send(.snapshot(wire.snapshot(seq: 1, [WireFrames.simple("ws_a", name: "alpha", order: 0)])))
        let first = await waiter.until { titles($0, mac) == ["alpha"] }
        #expect(first?.connection == .live(path: "relay"))
        #expect(first?.value.first?.capabilities == .all)
        await channel.send(.event(wire.event(seq: 2, "workspace.upsert", [
            "workspace": WireFrames.simple("ws_b", name: "beta", order: 1),
        ])))
        #expect(await waiter.until { titles($0, mac) == ["alpha", "beta"] } != nil)
    }

    @Test func gapRequestsExactlyOneSnapshot() async throws {
        let (source, factory, _) = make()
        var waiter = SnapshotWaiter(await source.updates())
        let channel = factory[mac]
        await channel.waitForSubscriber()
        await channel.send(.live(path: nil, caps: allCaps))
        await channel.send(.snapshot(wire.snapshot(seq: 1, [WireFrames.simple("ws_a", name: "alpha", order: 0)])))
        _ = await waiter.until { titles($0, mac) == ["alpha"] }
        await channel.send(.event(wire.event(seq: 5, "workspace.remove", ["workspace": .string("ws_a")])))
        await channel.send(.event(wire.event(seq: 6, "workspace.remove", ["workspace": .string("ws_a")])))
        let stale = await waiter.until { $0.value.first?.isResyncing == true }
        for _ in 0..<1000 where await channel.snapshotRequests < 1 { await Task.yield() }
        #expect(stale.map { titles($0, mac) } == ["alpha"])
        await channel.send(.snapshot(wire.snapshot(seq: 6, [])))
        #expect(await waiter.until { $0.value.first?.isResyncing == false && titles($0, mac).isEmpty } != nil)
        #expect(await channel.snapshotRequests == 1)
    }

    @Test func renameOverlaysUntilTheEcho() async throws {
        let (source, factory, _) = make()
        var waiter = SnapshotWaiter(await source.updates())
        let channel = factory[mac]
        await channel.waitForSubscriber()
        await channel.send(.live(path: nil, caps: allCaps))
        await channel.send(.snapshot(wire.snapshot(seq: 1, [WireFrames.simple("ws_a", name: "alpha", order: 0)])))
        _ = await waiter.until { titles($0, mac) == ["alpha"] }
        await channel.setAnswer { op in
            .applied(ResultFrame(tx: "tx_9", idempotencyKey: op.idempotencyKey, value: .object([:]), revision: "2", replayed: false))
        }
        let key = IntentKey(rawValue: "rename-key-1")
        let receipt = try await source.perform(.rename(workspaceID: "ws_a", title: "renamed"), key: key)
        guard case .committed(let committedKey, _) = receipt else { Issue.record("not committed"); return }
        #expect(committedKey == key)
        let sent = await channel.submitted
        #expect(sent.map(\.op) == ["workspace.rename"])
        #expect(sent.first?.idempotencyKey == "rename-key-1")
        // The owner has not echoed yet: the overlay shows the new name.
        #expect(titles(await source.current, mac) == ["renamed"])
        await channel.send(.event(wire.event(seq: 2, "workspace.upsert", [
            "workspace": WireFrames.simple("ws_a", name: "renamed", order: 0),
        ])))
        // The echo settles the intent: the confirmed mirror says the same.
        await channel.send(.event(wire.event(seq: 3, "workspace.status.set", [
            "tab": .string("tab_a"), "status": .string("idle"), "unread": .int(0),
        ])))
        #expect(await waiter.until { titles($0, mac) == ["renamed"] && $0.value.first?.workspaces.first?.panes.isEmpty == false } != nil)
    }

    @Test func rejectRefusesAndRestores() async throws {
        let (source, factory, _) = make()
        var waiter = SnapshotWaiter(await source.updates())
        let channel = factory[mac]
        await channel.waitForSubscriber()
        await channel.send(.live(path: nil, caps: allCaps))
        await channel.send(.snapshot(wire.snapshot(seq: 1, [WireFrames.simple("ws_a", name: "alpha", order: 0)])))
        _ = await waiter.until { titles($0, mac) == ["alpha"] }
        await channel.setAnswer { op in
            .rejected(RejectFrame(tx: "tx_1", idempotencyKey: op.idempotencyKey, code: "workspace.not_found",
                                  message: "No such workspace", retryable: false, replayed: false))
        }
        let receipt = try await source.perform(.close(workspaceID: "ws_a"), key: IntentKey(rawValue: "close-key-1"))
        #expect(receipt == .refused(key: IntentKey(rawValue: "close-key-1"), reason: "No such workspace"))
        #expect(titles(await source.current, mac) == ["alpha"])
    }

    @Test func offlineRefusesWithoutLogging() async throws {
        let (source, factory, _) = make()
        var waiter = SnapshotWaiter(await source.updates())
        let channel = factory[mac]
        await channel.waitForSubscriber()
        await channel.send(.live(path: nil, caps: allCaps))
        await channel.send(.snapshot(wire.snapshot(seq: 1, [WireFrames.simple("ws_a", name: "alpha", order: 0)])))
        _ = await waiter.until { titles($0, mac) == ["alpha"] }
        await channel.send(.offline(reason: "Asleep"))
        let offline = await waiter.until { $0.value.first?.isReachable == false }
        #expect(offline?.value.first?.offlineReason == "Asleep")
        #expect(offline?.value.first?.capabilities == [])
        #expect(offline?.connection == .offline(reason: nil))
        await #expect(throws: FeatureSourceError.offline) {
            try await source.perform(.close(workspaceID: "ws_a"), key: IntentKey())
        }
        #expect(await channel.submitted.isEmpty)
        #expect(titles(await source.current, mac) == ["alpha"])
    }

    @Test func failedSendDropsTheOverlay() async throws {
        let (source, factory, _) = make()
        var waiter = SnapshotWaiter(await source.updates())
        let channel = factory[mac]
        await channel.waitForSubscriber()
        await channel.send(.live(path: nil, caps: allCaps))
        await channel.send(.snapshot(wire.snapshot(seq: 1, [WireFrames.simple("ws_a", name: "alpha", order: 0)])))
        _ = await waiter.until { titles($0, mac) == ["alpha"] }
        await #expect(throws: FeatureSourceError.offline) {
            try await source.perform(.markRead(workspaceID: "ws_a"), key: IntentKey())
        }
        #expect(await channel.submitted.count == 1)
        #expect(await source.current.value.first?.workspaces.count == 1)
    }

    @Test func capsGateCloseAndRead() async throws {
        let (source, factory, _) = make()
        var waiter = SnapshotWaiter(await source.updates())
        let channel = factory[mac]
        await channel.waitForSubscriber()
        await channel.send(.live(path: nil, caps: []))
        let live = await waiter.until { $0.value.first?.isReachable == true }
        #expect(live?.value.first?.capabilities == [.create, .rename])
    }

    @Test func unknownWorkspaceIsNotFound() async throws {
        let (source, _, _) = make()
        _ = await source.updates()
        await #expect(throws: FeatureSourceError.notFound("ws_zz")) {
            try await source.perform(.close(workspaceID: "ws_zz"), key: IntentKey())
        }
    }

    @Test func directoryChangesAddAndRemoveHosts() async throws {
        let (source, factory, directory) = make([HostID("h_mac1"), HostID("h_mini")])
        var waiter = SnapshotWaiter(await source.updates())
        #expect(await waiter.until { $0.value.map(\.hostID) == [mac, mini] } != nil)
        await factory[mini].waitForSubscriber()
        await directory.update([WorkspaceHostDescriptor(id: mac, name: "Studio")])
        let after = await waiter.until { $0.value.map(\.hostID) == [mac] }
        #expect(after?.value.first?.hostName == "Studio")
        #expect(await factory[mini].closed)
    }

    @Test func emptyDirectoryIsLiveAndEmpty() async throws {
        let directory = StaticHostDirectory([])
        let source = ControlPlaneWorkspaceSource(directory: directory, channels: UnavailableWorkspaceChannelFactory(reason: "x"))
        var waiter = SnapshotWaiter(await source.updates())
        let loaded = await waiter.until { $0.connection == .live(path: nil) }
        #expect(loaded?.value.isEmpty == true)
    }

    @Test func unavailableChannelShowsTheReason() async throws {
        let directory = StaticHostDirectory([WorkspaceHostDescriptor(id: HostID("h_mac1"), name: "Mac")])
        let source = ControlPlaneWorkspaceSource(
            directory: directory, channels: UnavailableWorkspaceChannelFactory(reason: "Control plane unavailable"))
        var waiter = SnapshotWaiter(await source.updates())
        let offline = await waiter.until { $0.value.first?.offlineReason != nil }
        #expect(offline?.value.first?.offlineReason == "Control plane unavailable")
        #expect(offline?.connection == .offline(reason: nil))
    }

    @Test func lastSubscriberLeavingClosesChannels() async throws {
        let (source, factory, _) = make()
        let reader = Task { for await _ in await source.updates() {} }
        await factory[mac].waitForSubscriber()
        reader.cancel()
        await waitUntilClosed(factory[mac])
        #expect(await factory[mac].closed)
    }

    @Test func reopenResumesFromTheKeptSeq() async throws {
        let (source, factory, _) = make()
        let channel = factory[mac]
        let reader = Task { for await _ in await source.updates() {} }
        await channel.waitForSubscriber()
        await channel.send(.live(path: nil, caps: allCaps))
        await channel.send(.snapshot(wire.snapshot(seq: 1, [WireFrames.simple("ws_a", name: "alpha", order: 0)])))
        while titles(await source.current, mac) != ["alpha"] { await Task.yield() }
        reader.cancel()
        await waitUntilClosed(channel)
        await channel.reopenedForTest()
        var waiter = SnapshotWaiter(await source.updates())
        await channel.waitForSubscriber()
        await channel.send(.live(path: nil, caps: allCaps))
        // A resumed stream delivers the next event without a snapshot.
        await channel.send(.event(wire.event(seq: 2, "workspace.upsert", [
            "workspace": WireFrames.simple("ws_b", name: "beta", order: 1),
        ])))
        #expect(await waiter.until { titles($0, mac) == ["alpha", "beta"] } != nil)
        #expect(await channel.snapshotRequests == 0)
    }

    @Test func reconnectRetriesALostResync() async throws {
        let (source, factory, _) = make()
        var waiter = SnapshotWaiter(await source.updates())
        let channel = factory[mac]
        await channel.waitForSubscriber()
        await channel.send(.live(path: nil, caps: allCaps))
        await channel.send(.snapshot(wire.snapshot(seq: 1, [WireFrames.simple("ws_a", name: "alpha", order: 0)])))
        _ = await waiter.until { titles($0, mac) == ["alpha"] }
        await channel.send(.event(wire.event(seq: 9, "workspace.remove", ["workspace": .string("ws_a")])))
        _ = await waiter.until { $0.value.first?.isResyncing == true }
        await channel.send(.offline(reason: nil))
        _ = await waiter.until { $0.value.first?.isReachable == false }
        await channel.send(.live(path: nil, caps: allCaps))
        _ = await waiter.until { $0.value.first?.isReachable == true }
        // The request is sent from a child task; let it run.
        for _ in 0..<1000 where await channel.snapshotRequests < 2 { await Task.yield() }
        #expect(await channel.snapshotRequests == 2)
    }

    private func waitUntilClosed(_ channel: FakeWorkspaceChannel) async {
        while await !channel.closed { await Task.yield() }
    }
}
