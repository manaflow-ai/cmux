import CmuxiOSCloudCore
import CmuxiOSFeatureKit
import CmuxMobileWire
import Foundation
import Testing

struct WireCloudMachineSourceTests {
    let api = FakeCloudAPI()
    let transport = FakeCloudTransport()

    func makeSource() -> WireCloudMachineSource {
        WireCloudMachineSource(apiBaseURL: URL(string: "https://api.cmux.test")!, api: api, credentials: FakeCredentials(),
                               transport: transport, backoff: (.milliseconds(1), .milliseconds(2)))
    }

    func snapshotFrame(_ seq: Int) -> JSONValue {
        .object(["t": .string("snapshot"), "stream": .string("cloud:team_a"), "seq": .int(Int64(seq)),
                 "state": .object(["team": .string("team_a"), "rev": .int(Int64(seq))])])
    }

    func upsertFrame(_ seq: Int, _ machine: JSONValue) -> JSONValue {
        .object(["t": .string("event"), "seq": .int(Int64(seq)), "event": .string("cloud.machine.upsert"),
                 "data": .object(["machine": machine])])
    }

    @Test func subscribesThenReadsTheListAndPlanOnSnapshot() async throws {
        await api.set(machines: [CloudJSON.machine("vm_a", revision: 3, name: "box")], revision: 3)
        let source = makeSource()
        var updates = await source.updates().makeAsyncIterator()
        let socket = await transport.connection(0)
        await socket.outbox.wait(count: 1)
        #expect(await socket.outbox.frames == [#"{"t":"subscribe"}"#])
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "wss://api.cmux.test/v1/wire/cloud")
        #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "cmux.wire.v1, bearer.install-token")
        await socket.push(snapshotFrame(3))
        let loaded = try #require(await next(&updates) { $0.value.isLoaded && $0.value.plan != nil })
        #expect(loaded.connection.isLive)
        #expect(loaded.value.machines.map(\.name) == ["box"])
        #expect(loaded.value.plan?.planID == "dev")
    }

    @Test func liveEventsApplyAndAGapResyncsOnce() async throws {
        await api.set(machines: [CloudJSON.machine("vm_a", revision: 3)], revision: 3)
        let source = makeSource()
        var updates = await source.updates().makeAsyncIterator()
        let socket = await transport.connection(0)
        await socket.push(snapshotFrame(3))
        _ = await next(&updates) { $0.value.isLoaded }
        await socket.push(upsertFrame(4, CloudJSON.machine("vm_a", status: "pausing", revision: 4)))
        _ = try #require(await next(&updates) { $0.value.machine("vm_a")?.status == .pausing })
        // seq 6 skips 5: one snapshot.request, later events dropped until the snapshot.
        await socket.push(upsertFrame(6, CloudJSON.machine("vm_a", status: "paused", revision: 6)))
        await socket.push(upsertFrame(7, CloudJSON.machine("vm_a", status: "running", revision: 7)))
        await socket.outbox.wait(count: 2)
        #expect(await socket.outbox.frames.last == #"{"t":"snapshot.request"}"#)
        await api.set(machines: [CloudJSON.machine("vm_a", status: "running", revision: 7)], revision: 7)
        await socket.push(snapshotFrame(7))
        _ = try #require(await next(&updates) { $0.value.machine("vm_a")?.status == .running })
        #expect(await socket.outbox.frames.count == 2)
        #expect(await api.count("cloud.machine.list") == 2)
    }

    @Test func removedEventsDropTheMachine() async throws {
        await api.set(machines: [CloudJSON.machine("vm_a", revision: 3), CloudJSON.machine("vm_b", revision: 2)], revision: 3)
        let source = makeSource()
        var updates = await source.updates().makeAsyncIterator()
        let socket = await transport.connection(0)
        await socket.push(snapshotFrame(3))
        _ = await next(&updates) { $0.value.machines.count == 2 }
        await socket.push(.object(["t": .string("event"), "seq": .int(4), "event": .string("cloud.machine.removed"),
                                   "data": .object(["machine": .string("vm_b"), "revision": .string("4")])]))
        let after = try #require(await next(&updates) { $0.value.machines.count == 1 })
        #expect(after.value.machines.map(\.id) == ["vm_a"])
    }

    @Test func intentsGoAsTheSessionWithOneKeyAndOverlayUntilAnswered() async throws {
        await api.set(machines: [CloudJSON.machine("vm_a", revision: 3)], revision: 3)
        await api.set(replies: [.committed(value: .object(["machine": CloudJSON.machine("vm_a", status: "pausing", revision: 4)]),
                                           revision: 4)])
        let source = makeSource()
        var updates = await source.updates().makeAsyncIterator()
        let socket = await transport.connection(0)
        await socket.push(snapshotFrame(3))
        _ = await next(&updates) { $0.value.isLoaded }
        await api.holdNextMutation()
        let key = IntentKey()
        let task = Task { try await source.perform(.pause(machine: "vm_a"), key: key) }
        await api.waitForHeld()
        _ = try #require(await next(&updates) { $0.value.machine("vm_a")?.status == .pausing })
        await api.release()
        let receipt = try await task.value
        #expect(receipt == .committed(key: key, revision: 4))
        let call = try #require(await api.calls.last { $0.op == "cloud.machine.pause" })
        #expect(call == FakeCloudAPI.Call(op: "cloud.machine.pause", key: key.rawValue, principal: .session,
                                          params: ["machine": .string("vm_a")]))
        // The result is the owner's record, so the mirror keeps `pausing` at revision 4.
        let settled = try #require(await next(&updates) { $0.value.machine("vm_a")?.revision == 4 })
        #expect(settled.value.machine("vm_a")?.status == .pausing)
    }

    @Test func indeterminateRetriesTheSameKey() async throws {
        await api.set(machines: [], revision: 1)
        await api.set(replies: [.rejected(code: "mutation.indeterminate", retryable: true),
                                .committed(value: .object(["machine": CloudJSON.machine("vm_new", status: "provisioning", revision: 2)]),
                                           revision: 2)])
        let source = makeSource()
        var updates = await source.updates().makeAsyncIterator()
        let socket = await transport.connection(0)
        await socket.push(snapshotFrame(1))
        _ = await next(&updates) { $0.value.isLoaded }
        let key = IntentKey()
        let receipt = try await source.perform(.create(name: "new", size: CloudMachineSize(memoryMB: 2048)), key: key)
        #expect(receipt == .committed(key: key, revision: 2))
        let keys = await api.calls.filter { $0.op == "cloud.machine.create" }.map(\.key)
        #expect(keys == [key.rawValue, key.rawValue])
        _ = try #require(await next(&updates) { $0.value.machine("vm_new") != nil && $0.value.creating.isEmpty })
    }

    @Test func refusalsCarryTheOwnerCode() async throws {
        await api.set(replies: [.rejected(code: "cloud.quota.exceeded", retryable: false)])
        let source = makeSource()
        var updates = await source.updates().makeAsyncIterator()
        let socket = await transport.connection(0)
        await socket.push(snapshotFrame(1))
        _ = await next(&updates) { $0.connection.isLive }
        let key = IntentKey()
        let receipt = try await source.perform(.start(machine: "vm_a"), key: key)
        #expect(receipt == .refused(key: key, reason: "cloud.quota.exceeded"))
    }

    @Test func offlineRefusesWithoutSending() async {
        let source = makeSource()
        await #expect(throws: FeatureSourceError.offline) {
            try await source.perform(.delete(machine: "vm_a"), key: IntentKey())
        }
        #expect(await api.calls.isEmpty)
    }

    @Test func aClosedSocketReconnectsAndReadsAgain() async throws {
        await api.set(machines: [CloudJSON.machine("vm_a", revision: 3)], revision: 3)
        let source = makeSource()
        var updates = await source.updates().makeAsyncIterator()
        let first = await transport.connection(0)
        await first.push(snapshotFrame(3))
        _ = await next(&updates) { $0.value.isLoaded }
        await first.inbox.close()
        _ = await next(&updates) { if case .offline = $0.connection { true } else { false } }
        let second = await transport.connection(1)
        await second.outbox.wait(count: 1)
        await second.push(snapshotFrame(3))
        _ = try #require(await next(&updates) { $0.connection.isLive })
        #expect(await api.count("cloud.machine.list") >= 1)
    }
}
