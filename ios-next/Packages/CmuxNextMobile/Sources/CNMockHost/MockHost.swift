// DEVELOPMENT FIXTURE. Nothing in this module talks to a real Mac. It exists
// so UI work, previews, screenshots and offline tests have a believable host.

import CNCore
import CNTransport
import Foundation

/// An in-process demo host behind `LoopbackTransport` that implements the
/// whole PROTOCOL §4 surface with fixture data: Chief conversations, agent
/// sessions with streaming replies, ANSI terminals and browser tabs that
/// stream generated JPEG frames.
///
/// Development fixture only; never ship it as a connection target.
public final class MockHost: Sendable {
    public struct Options: Sendable {
        public var hostId: String
        public var hostName: String
        /// Speeds up every simulated delay (typing, token streaming, frame
        /// pacing). Tests use a large value.
        public var speed: Double
        /// Browser frame rate cap.
        public var browserFPS: Double
        public var clock: any Clock<Duration>

        public init(hostId: String = MockHost.defaultHostId, hostName: String = "Demo MacBook Pro", speed: Double = 1,
                    browserFPS: Double = 8, clock: any Clock<Duration> = ContinuousClock()) {
            self.hostId = hostId; self.hostName = hostName; self.speed = speed; self.browserFPS = browserFPS; self.clock = clock
        }
    }

    public static let defaultHostId = "h_demo_macbook"

    public let options: Options
    let engine: MockEngine

    public init(options: Options = Options()) {
        self.options = options
        self.engine = MockEngine(options: options)
    }

    /// A `Connector` whose every connect opens a new loopback link to this
    /// host. State (conversations, terminals, tabs) is shared across links.
    public func makeConnector() -> any Connector {
        MockConnector(host: self)
    }

    /// Opens one link and returns its phone end.
    public func connectLoopback() -> LoopbackTransport {
        let (client, server) = LoopbackTransport.makePair()
        let session = MockServerSession(link: Link(transport: server), engine: engine)
        session.start()
        return client
    }

    /// A `HostRecord` for host pickers and settings screens.
    public var hostRecord: HostRecord {
        let now = Date().epochMillis
        return HostRecord(id: options.hostId, name: options.hostName, os: "macOS 26.1", online: true,
                          lastSeenAt: now, createdAt: now - 14 * 86_400_000)
    }

    /// Drops every open link, as if the network went away. Connections
    /// reconnect through their `HostConnection`.
    public func dropAllLinks() async {
        await engine.dropAllLinks()
    }
}

struct MockConnector: Connector {
    let host: MockHost

    func connect(hostId: String) async throws -> any LinkTransport {
        guard hostId == host.options.hostId else {
            throw TransportError.connectFailed("Unknown demo host \(hostId)")
        }
        return host.connectLoopback()
    }
}

/// The host end of one link: decodes control messages and frames and hands
/// them to the engine.
final class MockServerSession: Sendable {
    let id = UUID()
    let link: Link
    let engine: MockEngine

    init(link: Link, engine: MockEngine) {
        self.link = link
        self.engine = engine
    }

    func start() {
        Task {
            await engine.register(self)
            var helloDone = false
            for await event in link.events {
                switch event {
                case .message(.control, let data):
                    guard let env = try? JSONDecoder().decode(ControlEnvelope.self, from: data), env.t == .req, let id = env.id else { continue }
                    let method = env.m ?? ""
                    if !helloDone && method != HostMethod.hello.rawValue {
                        reply(.failure(id: id, error: RPCError(code: .unauthorized, message: "host.hello first")))
                        continue
                    }
                    if method == HostMethod.hello.rawValue { helloDone = true }
                    do {
                        let result = try await engine.handle(method: method, params: env.p ?? .object([:]), session: self)
                        reply(.success(id: id, result: result))
                    } catch let error as RPCError {
                        reply(.failure(id: id, error: error))
                    } catch {
                        reply(.failure(id: id, error: RPCError(code: .badRequest, message: "\(method): \(error)")))
                    }
                case .message(_, let data):
                    guard helloDone, let frame = try? StreamFrame(decoding: data), frame.kind == .termInput else { continue }
                    await engine.terminalInput(streamId: frame.streamId, bytes: frame.payload)
                case .pathChanged:
                    break
                case .closed:
                    break
                }
            }
            await engine.unregister(self)
        }
    }

    func reply(_ envelope: ControlEnvelope) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? link.send(data, on: .control)
    }

    func sendEvent(_ data: Data) {
        try? link.send(data, on: .control)
    }

    func sendFrame(_ frame: StreamFrame) {
        try? link.send(frame.encoded(), on: frame.kind.lane)
    }
}
