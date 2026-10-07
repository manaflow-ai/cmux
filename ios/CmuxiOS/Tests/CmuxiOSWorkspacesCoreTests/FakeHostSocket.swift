import CmuxControlPlane
import CmuxMobileWire
import Foundation

/// The server end of one fake `/v1/wire/host/<host>` socket.
final class FakeHostSocket: Sendable {
    let toServer = TestFrameQueue()
    let toClient = TestFrameQueue()
    let url: URL
    let protocols: [String]

    init(url: URL, protocols: [String]) {
        self.url = url
        self.protocols = protocols
    }

    func next() async throws -> MobileFrame {
        try MobileFrame(decoding: Data(try await toServer.pop().utf8))
    }

    func send(_ frame: MobileFrame) throws {
        toClient.push(String(decoding: try frame.encoded(), as: UTF8.self))
    }
}

/// The client end.
final class FakeHostConnection: ControlPlaneConnection {
    let socket: FakeHostSocket
    init(socket: FakeHostSocket) { self.socket = socket }
    func send(_ text: String) async throws { socket.toServer.push(text) }
    func receive() async throws -> String { try await socket.toClient.pop() }
    func close(code: Int) async {
        socket.toServer.finish(ControlPlaneCloseError(code: code))
        socket.toClient.finish(ControlPlaneCloseError(code: code))
    }
}

/// Hands each connect to the test as a `FakeHostSocket`.
final class FakeHostTransport: ControlPlaneTransport, Sendable {
    let sockets: AsyncStream<FakeHostSocket>
    private let sink: AsyncStream<FakeHostSocket>.Continuation

    init() { (sockets, sink) = AsyncStream.makeStream(of: FakeHostSocket.self) }

    func connect(url: URL, protocols: [String]) async throws -> any ControlPlaneConnection {
        let socket = FakeHostSocket(url: url, protocols: protocols)
        sink.yield(socket)
        return FakeHostConnection(socket: socket)
    }
}
