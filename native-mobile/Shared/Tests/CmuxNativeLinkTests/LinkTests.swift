import Foundation
import Testing
import CmuxNativeWire
@testable import CmuxNativeLink

/// Echoes every line back on the same channel.
final class EchoDelegate: HostAcceptorDelegate {
    func hostAcceptor(_ acceptor: any HostAcceptor, didOpen channel: any LinkChannel, from peer: LinkPeer) {
        Task {
            for await line in channel.incoming {
                var reply = Data("{\"label\":\"\(channel.label)\",\"echo\":".utf8)
                reply.append(line)
                reply.append(Data("}\n".utf8))
                try? await channel.send(reply)
            }
        }
    }
}

func firstLine(_ channel: any LinkChannel, timeout: Duration = .seconds(20)) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            for await line in channel.incoming { return line }
            throw LinkError.channelClosed
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw LinkError.timeout("read")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

func waitForConnected(_ link: any HostLink, timeout: Duration = .seconds(30)) async throws -> LinkState {
    try await withThrowingTaskGroup(of: LinkState.self) { group in
        group.addTask {
            for await state in link.state {
                if case .connected = state { return state }
                if state.isTerminal { throw LinkError(code: "terminal", message: "\(state)") }
            }
            throw LinkError.closed
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw LinkError.timeout("connect")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

@Suite(.serialized) struct LinkTests {
    @Test func stateBroadcasterReplaysCurrentToLateSubscribers() async {
        let b = StateBroadcaster<LinkState>(.connecting)
        b.send(.connected(.direct))
        var it = b.stream().makeAsyncIterator()
        #expect(await it.next() == .connected(.direct))
        b.finish(with: .closed)
        #expect(await it.next() == .closed)
        #expect(await it.next() == nil)
        var late = b.stream().makeAsyncIterator()
        #expect(await late.next() == .closed)
        #expect(await late.next() == nil)
    }

    @Test func loopbackEchoesSmallAndFragmentedLines() async throws {
        let acceptor = LoopbackHostAcceptor()
        let echo = EchoDelegate()
        acceptor.setDelegate(echo)
        acceptor.start()
        let port = try await acceptor.port()
        let link = LoopbackHostLink(port: port)
        let channel = try await link.openChannel(label: "svc")
        try await channel.send(Data("{\"id\":1}\n".utf8))
        let reply = try await firstLine(channel)
        #expect(String(decoding: reply, as: UTF8.self) == #"{"label":"svc","echo":{"id":1}}"#)

        let big = "{\"blob\":\"" + String(repeating: "x", count: 200_000) + "\"}"
        try await channel.send(Data(big.utf8))
        let bigReply = try await firstLine(channel)
        #expect(bigReply.count == big.utf8.count + #"{"label":"svc","echo":}"#.utf8.count)
        link.close()
        acceptor.stop()
    }

    @Test func webRTCInProcessEchoOverInMemorySignaling() async throws {
        let hub = InMemorySignalingHub()
        let acceptor = WebRTCHostAcceptor(signaling: { hub.hostTransport() }, iceServers: { [] })
        let echo = EchoDelegate()
        acceptor.setDelegate(echo)
        acceptor.start()
        // No wait for the host: an early offer gets host_offline and the
        // link retries with backoff.

        let link = WebRTCHostLink(signaling: { hub.phoneTransport(userID: "u1") }, iceServers: { [] })
        let state = try await waitForConnected(link)
        #expect(state == .connected(.direct))
        // A late subscriber still sees connected.
        var late = link.state.makeAsyncIterator()
        if case .connected = await late.next() {} else { Issue.record("late subscriber missed connected") }

        let a = try await link.openChannel(label: "svc")
        let b = try await link.openChannel(label: "daemon:\(UUID().uuidString)")
        try await a.send(Data("{\"id\":1}\n".utf8))
        try await b.send(Data("{\"id\":2}\n".utf8))
        #expect(String(decoding: try await firstLine(a), as: UTF8.self) == #"{"label":"svc","echo":{"id":1}}"#)
        #expect(String(decoding: try await firstLine(b), as: UTF8.self).hasSuffix(#""echo":{"id":2}}"#))

        let big = "{\"blob\":\"" + String(repeating: "é", count: 150_000) + "\"}"
        try await a.send(Data(big.utf8))
        let bigReply = try await firstLine(a)
        #expect(bigReply.count == big.utf8.count + #"{"label":"svc","echo":}"#.utf8.count)

        #expect(acceptor.peers.count == 1)
        #expect(acceptor.peers.first?.userID == "u1")
        link.close()
        acceptor.stop()
    }

    @Test func webRTCReconnectsAfterHostRestart() async throws {
        let hub = InMemorySignalingHub()
        let echo = EchoDelegate()
        let first = WebRTCHostAcceptor(signaling: { hub.hostTransport() }, iceServers: { [] })
        first.setDelegate(echo)
        first.start()
        let link = WebRTCHostLink(signaling: { hub.phoneTransport(userID: "u1") }, iceServers: { [] })
        _ = try await waitForConnected(link)
        let before = try await link.openChannel(label: "svc")

        var states = link.state.makeAsyncIterator()
        _ = await states.next() // current: connected
        first.stop()
        // The old channel finishes and the link reports reconnecting.
        for await _ in before.incoming {}
        var sawReconnecting = false
        while let state = await states.next() {
            if state == .reconnecting { sawReconnecting = true; break }
        }
        #expect(sawReconnecting)

        let second = WebRTCHostAcceptor(signaling: { hub.hostTransport() }, iceServers: { [] })
        second.setDelegate(echo)
        second.start()
        _ = try await waitForConnected(link)
        let after = try await link.openChannel(label: "svc")
        try await after.send(Data("{\"id\":5}\n".utf8))
        #expect(String(decoding: try await firstLine(after), as: UTF8.self) == #"{"label":"svc","echo":{"id":5}}"#)
        link.close()
        second.stop()
    }
}
