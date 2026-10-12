import Foundation
import Synchronization
import Testing
import CmuxNativeLink
import CmuxNativeWire
@testable import CmuxNativeHost

/// An in-memory channel: the test feeds `incoming`, and `close()` finishes it
/// the way `HostPeer.close()` finishes a WebRTC channel.
final class MemoryChannel: LinkChannel {
    let label: String
    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    let sent = Mutex<[Data]>([])

    init(label: String) {
        self.label = label
        (incoming, continuation) = AsyncStream<Data>.makeStream()
    }

    func feed(_ line: String) { continuation.yield(Data(line.utf8)) }
    func send(_ data: Data) async throws { sent.withLock { $0.append(data) } }
    func close() { continuation.finish() }
}

/// A fake daemon that accepts one connection and reports what it read and
/// when the host closed the socket.
final class EOFDaemon: Sendable {
    enum Event: Sendable { case bytes(Int), eof }
    let path = "/tmp/nb-\(UUID().uuidString.prefix(6)).sock"
    let events: AsyncStream<Event>
    private let listener: Int32

    init() {
        let (events, continuation) = AsyncStream<Event>.makeStream()
        self.events = events
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let listener = self.listener
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        listen(listener, 4)
        Thread.detachNewThread {
            let fd = accept(listener, nil, nil)
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                continuation.yield(.bytes(n))
            }
            continuation.yield(.eof)
            continuation.finish()
            close(fd)
        }
    }

    func stop() {
        close(listener)
        unlink(path)
    }
}

@Suite struct BridgeTeardownTests {
    /// Removing a peer closes its channels; each daemon bridge must then close
    /// its daemon socket so the daemon detaches the stale client.
    @Test func closingThePhoneChannelClosesTheDaemonSocket() async throws {
        let daemon = EOFDaemon()
        defer { daemon.stop() }
        let channel = MemoryChannel(label: "daemon:test")
        let bridge = DaemonChannelBridge(socketPath: daemon.path, policy: DaemonChannelPolicy(deviceID: "dev1"))
        let run = Task { await bridge.run(channel: channel) }

        var events = daemon.events.makeAsyncIterator()
        channel.feed(#"{"id":1,"cmd":"ping"}"#)
        guard case .bytes = await events.next() else {
            Issue.record("daemon never saw the ping")
            return
        }
        channel.close()
        #expect(await run.value == .phoneClosed)
        guard case .eof = await events.next() else {
            Issue.record("daemon socket stayed open")
            return
        }
    }
}
