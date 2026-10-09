import CmuxControlPlane
import CmuxiOSFeatureKit
import CmuxMobileWire
@testable import CmuxiOSWorkspacesCore
import Foundation
import Testing

@Suite struct ControlPlaneChannelTests {
    let reasons = ControlPlaneChannelReasons(macOffline: "Mac offline", macSleeping: "Asleep", macPaused: "Paused",
                                             signedOut: "Signed out", refused: "Refused")
    let host = WorkspaceHostDescriptor(id: HostID("h_mac1"), name: "Mac")

    func factory(_ transport: FakeHostTransport) -> ControlPlaneWorkspaceChannelFactory {
        ControlPlaneWorkspaceChannelFactory(
            apiBaseURL: URL(string: "https://api.example.com/base")!, appVersion: "1.2", reasons: reasons,
            transport: transport, reconnect: ReconnectPolicy(delays: [.zero], sleep: { _ in }),
            install: { "in_phone1" }, token: { "tok123" })
    }

    func hostState(_ presence: String, caps: [String]) -> JSONValue {
        .object(["host": .string("h_mac1"), "presence": .string(presence), "viewers": .int(1), "devices": .array([]),
                 "caps": .object(["proto": .object(["min": .int(1), "max": .int(1)]), "caps": .array(caps.map { .string($0) })]),
                 "at": .int(1)])
    }

    @Test func socketURL() {
        let url = factory(FakeHostTransport()).socketURL(for: host)
        #expect(url.absoluteString == "wss://api.example.com/v1/wire/host/h_mac1")
    }

    @Test func stateMapping() {
        func state(_ socket: ControlPlaneState, _ presence: String?) -> WorkspaceChannelState {
            ControlPlaneWorkspaceChannel.state(socket: socket, presence: presence, caps: ["workspace.read"],
                                               failure: nil, reasons: reasons)
        }
        let ok = ControlPlaneState.connected(HelloOKFrame(version: 1, caps: [], serverTime: 0, maxFrame: 1))
        #expect(state(ok, "online") == .live(path: "relay", caps: ["workspace.read"]))
        #expect(state(ok, "sleeping") == .offline(reason: "Asleep"))
        #expect(state(ok, "offline") == .offline(reason: "Mac offline"))
        #expect(state(ok, nil) == .connecting)
        #expect(state(.connecting(attempt: 0), "online") == .connecting)
        #expect(state(.disconnected(attempt: 1), "online") == .offline(reason: nil))
    }

    @Test func mirrorsAndSubmitsOverTheHostSocket() async throws {
        let transport = FakeHostTransport()
        let channel = factory(transport).channel(for: host)
        var states = await channel.states().makeAsyncIterator()
        var updates = await channel.updates().makeAsyncIterator()
        var sockets = transport.sockets.makeAsyncIterator()
        let socket = try #require(await sockets.next())
        #expect(socket.protocols == ["cmux.wire.v1", "bearer.tok123"])
        guard case .hello(let hello) = try await socket.next() else { Issue.record("no hello"); return }
        #expect(hello.client.install == "in_phone1")
        #expect(hello.client.platform == "ios")
        try socket.send(.helloOK(HelloOKFrame(version: 1, caps: ["read", "presence", "resume"], serverTime: 1, maxFrame: 131072)))
        // The client subscribes host: and workspace: and marks itself active.
        var subscribed: Set<String> = []
        var active = false
        while subscribed.count < 2 || !active {
            switch try await socket.next() {
            case .subscribe(let frame): if let stream = frame.stream { subscribed.insert(stream) }
            case .presenceSet(let frame): active = frame.state.active
            default: break
            }
        }
        #expect(subscribed == ["host:h_mac1", "workspace:h_mac1"])
        try socket.send(.snapshot(SnapshotFrame(stream: "host:h_mac1", seq: 1,
                                                state: hostState("online", caps: ["workspace.close", "workspace.read"]), decided: [])))
        let wire = WireFrames(host: "h_mac1")
        try socket.send(.snapshot(wire.snapshot(seq: 40, [WireFrames.simple("ws_a", name: "alpha", order: 0)])))
        while let state = await states.next(), state != .live(path: "relay", caps: ["workspace.close", "workspace.read"]) {}
        guard case .snapshot(let snapshot)? = await updates.next() else { Issue.record("no snapshot"); return }
        #expect(snapshot.seq == 40)

        let op = try WorkspaceOpEncoder(hostID: host.id).frame(for: .markRead(workspaceID: "ws_a"), key: IntentKey(rawValue: "read-key-01"))
        async let outcome = channel.submit(op)
        var sent: OpFrame?
        while sent == nil { if case .op(let frame) = try await socket.next() { sent = frame } }
        #expect(sent?.op == "workspace.read")
        try socket.send(.result(ResultFrame(tx: "tx_1", idempotencyKey: "read-key-01", value: .object([:]), revision: "41", replayed: false)))
        #expect(try await outcome == .applied(ResultFrame(tx: "tx_1", idempotencyKey: "read-key-01", value: .object([:]),
                                                          revision: "41", replayed: false)))

        // A resync resubscribes the workspace stream from scratch.
        await channel.requestSnapshot()
        var resubscribed = false
        while !resubscribed {
            if case .subscribe(let frame) = try await socket.next(), frame.stream == "workspace:h_mac1" {
                #expect(frame.afterSeq == nil)
                resubscribed = true
            }
        }

        // The Mac falls asleep: ops are refused locally.
        try socket.send(.event(EventFrame(stream: "host:h_mac1", seq: 2, tx: "tx_2", op: "host.presence.set",
                                          params: .object(["host": .string("h_mac1"), "presence": .string("sleeping")]),
                                          actor: ["identity": .string("host")], origin: .remote, at: 2)))
        while let state = await states.next(), state != .offline(reason: "Asleep") {}
        await #expect(throws: WorkspaceChannelError.notConnected) { try await channel.submit(op) }
        await channel.close()
    }

    @Test func missingInstallShowsSignedOut() async {
        let transport = FakeHostTransport()
        let factory = ControlPlaneWorkspaceChannelFactory(
            apiBaseURL: URL(string: "https://api.example.com")!, appVersion: "1", reasons: reasons, transport: transport,
            install: { throw CancellationError() }, token: { "t" })
        let channel = factory.channel(for: host)
        var states = await channel.states().makeAsyncIterator()
        while let state = await states.next(), state != .offline(reason: "Signed out") {}
        await channel.close()
    }
}
