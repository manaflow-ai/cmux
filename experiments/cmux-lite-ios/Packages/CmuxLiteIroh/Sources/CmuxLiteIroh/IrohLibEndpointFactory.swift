import Foundation
import IrohLib

/// Binds the generated IrohLib endpoint and wraps it in the experiment seam.
public struct IrohLibEndpointFactory: IrohEndpointFactory, Sendable {
    private let closeClock: any IrohCloseClock

    /// Creates the default native endpoint factory.
    public init() {
        closeClock = ContinuousIrohCloseClock()
    }

    init(closeClock: any IrohCloseClock) {
        self.closeClock = closeClock
    }

    /// Binds an endpoint using the requested relay mode, ALPN, and key.
    public func bind(
        configuration: IrohLibConfiguration
    ) async throws -> any IrohEndpointDriver {
        let builder = EndpointBuilder()
        switch configuration.relayMode {
        case .production:
            builder.applyN0()
        case .staging:
            builder.applyMinimal()
            builder.relayMode(mode: RelayMode.staging())
        case .disabled:
            builder.applyN0DisableRelay()
        }
        builder.alpns(alpns: [configuration.alpn])
        if let bindAddress = configuration.bindAddress {
            do {
                try builder.bindAddr(addr: bindAddress)
            } catch {
                throw IrohLibFailureMapper.openFailure(for: error)
            }
        }
        if let secretKeyBytes = configuration.secretKeyBytes {
            do {
                try builder.secretKey(bytes: secretKeyBytes)
            } catch {
                throw IrohLibFailureMapper.openFailure(for: error)
            }
        }

        do {
            let endpoint = try await builder.bind()
            return IrohLibEndpointDriver(
                endpoint: endpoint,
                maximumReceiveChunkBytes: configuration.maximumReceiveChunkBytes,
                closeDrainTimeout: configuration.closeDrainTimeout,
                closeClock: closeClock
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IrohLibFailureMapper.openFailure(for: error)
        }
    }
}

/// The concrete endpoint wrapper. It is a class so `close()` can run while a
/// native connect operation is suspended, which is required for cancellation
/// and foreground/background lifecycle handling.
final class IrohLibEndpointDriver: IrohEndpointDriver, @unchecked Sendable {
    private let endpoint: Endpoint
    private let maximumReceiveChunkBytes: UInt32
    private let closeDrainTimeout: Duration
    private let closeClock: any IrohCloseClock
    private let stateLock = NSLock()
    private var closed = false

    init(
        endpoint: Endpoint,
        maximumReceiveChunkBytes: UInt32,
        closeDrainTimeout: Duration,
        closeClock: any IrohCloseClock
    ) {
        self.endpoint = endpoint
        self.maximumReceiveChunkBytes = maximumReceiveChunkBytes
        self.closeDrainTimeout = closeDrainTimeout
        self.closeClock = closeClock
    }

    func localRoute() async throws -> IrohRoute {
        guard !isClosed() else {
            throw IrohOpenFailure.closed
        }
        return try IrohLibRouteAddress.makeRoute(for: endpoint.addr())
    }

    func connect(
        to route: IrohRoute,
        alpn: Data
    ) async throws -> any IrohConnection {
        guard !isClosed() else {
            throw IrohOpenFailure.closed
        }

        let address = try IrohLibRouteAddress.make(for: route)
        let endpointID = address.id()

        do {
            let connection = try await endpoint.connect(addr: address, alpn: alpn)
            guard !isClosed() else {
                try? connection.close(errorCode: 0, reason: Data())
                throw IrohOpenFailure.closed
            }
            guard connection.remoteId() == endpointID else {
                try? connection.close(
                    errorCode: 1,
                    reason: Data("endpoint identity mismatch".utf8)
                )
                throw IrohOpenFailure.unauthorized
            }
            do {
                let stream = try await connection.openBi()
                return IrohLibConnection(
                    connection: connection,
                    stream: stream,
                    maximumReceiveChunkBytes: maximumReceiveChunkBytes,
                    closeDrainTimeout: closeDrainTimeout,
                    closeClock: closeClock
                )
            } catch {
                try? connection.close(errorCode: 0, reason: Data())
                throw IrohLibFailureMapper.openFailure(for: error)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as IrohOpenFailure {
            throw failure
        } catch {
            throw IrohLibFailureMapper.openFailure(for: error)
        }
    }

    func accept(alpn: Data) async throws -> IrohIncomingConnection? {
        guard !isClosed() else {
            throw IrohOpenFailure.closed
        }

        while let incoming = await endpoint.acceptNext() {
            guard !isClosed() else {
                try? await incoming.refuse()
                throw IrohOpenFailure.closed
            }
            do {
                let accepting = try await incoming.accept()
                let offeredALPN = try await accepting.alpn()

                // Dropping an incompatible Accepting handle rejects that
                // candidate. Keep listening because one unrelated protocol
                // must not take the server endpoint offline.
                guard offeredALPN == alpn else {
                    continue
                }

                let connection = try await accepting.connect()
                guard connection.alpn() == alpn else {
                    try? connection.close(
                        errorCode: 0,
                        reason: Data("ALPN mismatch".utf8)
                    )
                    continue
                }

                let peerRoute = try IrohRoute(
                    endpointID: connection.remoteId().description
                )
                do {
                    let stream = try await connection.acceptBi()
                    return IrohIncomingConnection(
                        peerRoute: peerRoute,
                        connection: IrohLibConnection(
                            connection: connection,
                            stream: stream,
                            maximumReceiveChunkBytes: maximumReceiveChunkBytes,
                            closeDrainTimeout: closeDrainTimeout,
                            closeClock: closeClock
                        )
                    )
                } catch {
                    try? connection.close(errorCode: 0, reason: Data())
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as IrohOpenFailure {
                guard failure == .closed else {
                    continue
                }
                throw failure
            } catch {
                let failure = IrohLibFailureMapper.openFailure(for: error)
                guard failure != .closed else {
                    throw failure
                }
                // A malformed or incompatible incoming candidate is isolated
                // to that candidate. The listener remains available for the
                // next peer.
                continue
            }
        }

        return nil
    }

    func close() async {
        guard markClosed() else {
            return
        }
        try? await endpoint.close()
    }

    private func isClosed() -> Bool {
        stateLock.withLock { closed }
    }

    private func markClosed() -> Bool {
        stateLock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
    }
}

/// Converts the opaque experiment route into the generated binding value.
///
/// `EndpointAddr`'s generated constructor is intentionally nonthrowing because
/// it only stores strings. Endpoint-id parsing still happens here, before a
/// network operation can begin, so malformed discovery data becomes a normal
/// transport failure instead of a late native crash.
enum IrohLibRouteAddress {
    static func make(for route: IrohRoute) throws -> EndpointAddr {
        let endpointID: EndpointId
        do {
            endpointID = try EndpointId.fromString(s: route.endpointID)
        } catch {
            throw IrohOpenFailure.invalidRoute
        }
        return EndpointAddr(
            id: endpointID,
            relayUrl: route.relayURL,
            addresses: route.directAddresses
        )
    }

    /// Converts a native endpoint address into public route metadata.
    static func makeRoute(for address: EndpointAddr) throws -> IrohRoute {
        do {
            return try IrohRoute(
                endpointID: address.id().description,
                relayURL: address.relayUrl(),
                directAddresses: address.directAddresses()
            )
        } catch {
            throw IrohOpenFailure.invalidRoute
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
