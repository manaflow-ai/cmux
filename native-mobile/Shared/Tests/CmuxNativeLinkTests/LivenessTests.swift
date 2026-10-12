import Foundation
import Synchronization
import Testing
import CmuxNativeWire
@testable import CmuxNativeLink

/// A `LinkClock` that only moves when the test advances it.
final class ManualLinkClock: Sendable {
    private struct State {
        var now: Duration = .zero
        var nextID: UInt64 = 0
        var sleepers: [UInt64: (deadline: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]
        var sleeperWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var clock: LinkClock {
        LinkClock(now: { self.state.withLock { $0.now } }, sleep: { try await self.sleep(for: $0) })
    }

    private func sleep(for duration: Duration) async throws {
        let id: UInt64 = state.withLock { s in
            defer { s.nextID += 1 }
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let (cancelled, waiters) = state.withLock { s -> (Bool, [CheckedContinuation<Void, Never>]) in
                    if Task.isCancelled { return (true, []) }
                    s.sleepers[id] = (s.now + duration, c)
                    defer { s.sleeperWaiters = [] }
                    return (false, s.sleeperWaiters)
                }
                if cancelled { c.resume(throwing: CancellationError()) }
                for w in waiters { w.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline passed.
    func advance(by duration: Duration) {
        let due = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
            s.now += duration
            let ready = s.sleepers.filter { $0.value.deadline <= s.now }
            for id in ready.keys { s.sleepers.removeValue(forKey: id) }
            return ready.values.map(\.continuation)
        }
        for c in due { c.resume() }
    }

    /// Returns once at least one task is sleeping on this clock.
    func waitForSleeper() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if !s.sleepers.isEmpty { return true }
                s.sleeperWaiters.append(c)
                return false
            }
            if ready { c.resume() }
        }
    }

    /// Advances in liveness-check steps, letting the checker run after each.
    func step(_ count: Int) async {
        for _ in 0..<count {
            await waitForSleeper()
            advance(by: PeerActivity.checkInterval)
        }
        await waitForSleeper()
    }
}

/// Echoes lines and records what the acceptor reports.
final class RecordingDelegate: HostAcceptorDelegate {
    enum Event: Sendable {
        case opened(any LinkChannel)
        case connected
        case timedOut(Duration)
        case disconnected
    }

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    init() {
        (events, continuation) = AsyncStream<Event>.makeStream()
    }

    func hostAcceptor(_ acceptor: any HostAcceptor, didOpen channel: any LinkChannel, from peer: LinkPeer) {
        continuation.yield(.opened(channel))
        Task {
            for await line in channel.incoming {
                var reply = Data("{\"echo\":".utf8)
                reply.append(line)
                reply.append(Data("}\n".utf8))
                try? await channel.send(reply)
            }
        }
    }

    func hostAcceptor(_ acceptor: any HostAcceptor, peerDidConnect peer: LinkPeer, path: LinkPathInfo?) {
        continuation.yield(.connected)
    }

    func hostAcceptor(_ acceptor: any HostAcceptor, peerDidTimeOut peer: LinkPeer, idle: Duration) {
        continuation.yield(.timedOut(idle))
    }

    func hostAcceptor(_ acceptor: any HostAcceptor, peerDidDisconnect peer: LinkPeer) {
        continuation.yield(.disconnected)
    }
}

@Suite(.serialized) struct LivenessTests {
    @Test func checkerFiresOnlyAfterIdleTimeoutWithOpenChannels() async {
        let manual = ManualLinkClock()
        let activity = PeerActivity(clock: manual.clock)
        let open = Atomic<Bool>(false)
        let result = Task { await activity.waitForTimeout(hasOpenChannels: { open.load(ordering: .relaxed) }) }
        // No channels: silence alone never times out.
        await manual.step(6)
        open.store(true, ordering: .relaxed)
        activity.touch() // t = 60
        await manual.step(4) // t = 100, idle 40
        activity.touch()     // t = 100
        await manual.step(4) // t = 140, idle 40
        manual.advance(by: PeerActivity.checkInterval) // idle 50
        #expect(await result.value == .seconds(50))
    }

    @Test func checkerStopsWhenCancelled() async {
        let manual = ManualLinkClock()
        let activity = PeerActivity(clock: manual.clock)
        let result = Task { await activity.waitForTimeout(hasOpenChannels: { true }) }
        await manual.waitForSleeper()
        result.cancel()
        #expect(await result.value == nil)
    }

    /// The host drops a WebRTC peer whose channels go silent although the
    /// connection never reports a failure, and closes its channels.
    @Test func silentWebRTCPeerTimesOutAndClosesItsChannels() async throws {
        let hub = InMemorySignalingHub()
        let manual = ManualLinkClock()
        let acceptor = WebRTCHostAcceptor(signaling: { hub.hostTransport() }, iceServers: { [] }, relayOnly: false, clock: manual.clock)
        let recorder = RecordingDelegate()
        acceptor.setDelegate(recorder)
        acceptor.start()
        var events = recorder.events.makeAsyncIterator()

        let link = WebRTCHostLink(signaling: { hub.phoneTransport(userID: "u1") }, iceServers: { [] })
        _ = try await waitForConnected(link)
        let channel = try await link.openChannel(label: "daemon:\(UUID().uuidString)")
        try await channel.send(Data(#"{"id":1,"cmd":"ping"}"#.utf8))
        #expect(String(decoding: try await firstLine(channel), as: UTF8.self) == #"{"echo":{"id":1,"cmd":"ping"}}"#)
        var hostChannel: (any LinkChannel)?
        while hostChannel == nil, let event = await events.next() {
            if case .opened(let c) = event { hostChannel = c }
        }

        await manual.step(4) // 40 s silent: still attached
        #expect(acceptor.peers.count == 1)
        try await channel.send(Data(#"{"id":2,"cmd":"ping"}"#.utf8))
        _ = try await firstLine(channel)
        await manual.step(4) // 40 s since the heartbeat
        #expect(acceptor.peers.count == 1)
        manual.advance(by: PeerActivity.checkInterval) // 50 s since the heartbeat

        var timedOut: Duration?
        while let event = await events.next() {
            if case .timedOut(let idle) = event { timedOut = idle }
            if case .disconnected = event { break }
        }
        #expect(timedOut == .seconds(50))
        #expect(acceptor.peers.isEmpty)
        // The host side of the channel finished, so its consumer ended.
        if let hostChannel { for await _ in hostChannel.incoming {} }
        link.close()
        acceptor.stop()
    }
}
