#if canImport(CnxFFI)
import CnxFFI
import Foundation

/// Dials Macs through the Rust cnx-link core (WebRTC or WireGuard).
public struct FFIMacLinkDialer: MacLinkDialer {
    public init() {}

    public func dial(_ endpoint: LinkEndpoint, transport: TransportKind, accessToken: String) async throws -> any MacLink {
        let observer = StateObserver()
        do {
            let handle = try await connect(
                baseUrl: endpoint.baseURL.absoluteString,
                token: accessToken,
                teamId: endpoint.teamID,
                deviceId: endpoint.deviceID,
                macDeviceId: endpoint.macDeviceID,
                transport: transport.ffi,
                observer: observer
            )
            return FFIMacLink(handle: handle, transport: transport, observer: observer)
        } catch let error as CnxError {
            throw error.linkError
        }
    }
}

final class FFIMacLink: MacLink, @unchecked Sendable {
    let transport: TransportKind
    let states: AsyncStream<LinkState>
    private let handle: LinkHandle
    private let observer: StateObserver

    init(handle: LinkHandle, transport: TransportKind, observer: StateObserver) {
        self.handle = handle
        self.transport = transport
        self.observer = observer
        self.states = observer.stream
        observer.yield(.connected(transport, handle.path().kind, rttMillis: nil))
    }

    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        do {
            return FFIChannel(handle: try await handle.openChannel(service: service, argsJson: json))
        } catch let error as CnxError {
            throw error.linkError
        }
    }

    func ping() async throws -> UInt32 {
        do { return try await handle.ping() } catch let error as CnxError { throw error.linkError }
    }

    func close() async {
        handle.close()
    }
}

final class FFIChannel: LinkChannel, @unchecked Sendable {
    private let handle: ChannelHandle
    let id: UInt32

    init(handle: ChannelHandle) {
        self.handle = handle
        self.id = handle.id()
    }

    func send(_ data: Data) async throws {
        do { try await handle.send(data: data) } catch let error as CnxError { throw error.linkError }
    }

    func receive() async throws -> Data? {
        switch await handle.recv() {
        case .data(let bytes): bytes
        case .closed: nil
        }
    }

    func close(code: String, reason: String) async {
        await handle.close(code: code, reason: reason)
    }
}

/// Bridges Rust link events into `LinkState`.
final class StateObserver: LinkObserver, @unchecked Sendable {
    let stream: AsyncStream<LinkState>
    private let continuation: AsyncStream<LinkState>.Continuation
    private let lock = NSLock()
    private var current: (TransportKind, LinkPathKind)?

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    func yield(_ state: LinkState) {
        continuation.yield(state)
    }

    func onEvent(event: LinkEvent) {
        lock.withLock {
            switch event {
            case .connecting(let transport):
                continuation.yield(.connecting(transport.kind))
            case .connected(let transport, let path):
                current = (transport.kind, path.kind)
                continuation.yield(.connected(transport.kind, path.kind, rttMillis: nil))
            case .pathChanged(let path):
                if let (transport, _) = current {
                    current = (transport, path.kind)
                    continuation.yield(.connected(transport, path.kind, rttMillis: nil))
                }
            case .rtt(let millis):
                if let (transport, path) = current {
                    continuation.yield(.connected(transport, path, rttMillis: millis))
                }
            case .disconnected(let reason):
                continuation.yield(.disconnected(reason: reason))
            }
        }
    }
}

extension TransportKind {
    var ffi: Transport { self == .webRTC ? .webRtc : .wireGuard }
}

extension Transport {
    var kind: TransportKind { self == .webRtc ? .webRTC : .wireGuard }
}

extension LinkPath {
    var kind: LinkPathKind {
        switch self {
        case .direct: .direct
        case .relay: .relay
        case .turn: .turn
        }
    }
}

extension CnxError {
    var linkError: LinkError {
        switch self {
        case .InvalidArgument(let message): LinkError(code: "invalid_argument", message: message)
        case .Signaling(let message): LinkError(code: "signaling", message: message)
        case .Refused(let code, let message): LinkError(code: code, message: message)
        case .Timeout: LinkError(code: "timeout", message: "The Mac didn't answer in time.")
        case .Transport(let message): LinkError(code: "transport", message: message)
        case .Closed(let message): LinkError(code: "closed", message: message)
        }
    }
}
#endif
