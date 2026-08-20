import Foundation
import IrohLib

protocol IrohCloseClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousIrohCloseClock: IrohCloseClock, Sendable {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

/// Adapts one IrohLib bidirectional stream to the cmux-lite native seam.
///
/// The class is intentionally `@unchecked Sendable`: generated IrohLib
/// handles are thread-safe, and the outer ``IrohByteStream`` actor serializes
/// each direction. A lock protects only the terminal close flag.
final class IrohLibConnection: IrohConnection, @unchecked Sendable {
    private let connection: Connection
    private let sendStream: SendStream
    private let receiveStream: RecvStream
    private let maximumReceiveChunkBytes: UInt32
    private let closeDrainTimeout: Duration
    private let closeClock: any IrohCloseClock
    private let stateLock = NSLock()
    private var closed = false

    init(
        connection: Connection,
        stream: BiStream,
        maximumReceiveChunkBytes: UInt32,
        closeDrainTimeout: Duration = .seconds(2),
        closeClock: any IrohCloseClock = ContinuousIrohCloseClock()
    ) {
        self.connection = connection
        sendStream = stream.send()
        receiveStream = stream.recv()
        self.maximumReceiveChunkBytes = maximumReceiveChunkBytes
        self.closeDrainTimeout = closeDrainTimeout
        self.closeClock = closeClock
    }

    func send(_ bytes: Data) async throws {
        guard !bytes.isEmpty else {
            return
        }
        guard !isClosed() else {
            throw IrohOpenFailure.closed
        }
        do {
            try await sendStream.writeAll(buf: bytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IrohLibFailureMapper.openFailure(for: error)
        }
    }

    func receive() async throws -> Data? {
        if isClosed() {
            return nil
        }
        do {
            let bytes = try await receiveStream.read(
                sizeLimit: maximumReceiveChunkBytes
            )
            return bytes.isEmpty ? nil : bytes
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IrohLibFailureMapper.openFailure(for: error)
        }
    }

    func close() async {
        guard markClosed() else {
            return
        }

        // Finish before closing the QUIC connection, then wait until Iroh has
        // observed the peer consume the stream. Closing the connection
        // immediately after queuing FIN can race the final protocol frame and
        // make a peer report transport failure instead of the explicit close.
        // The deadline branch force-closes the connection if the peer vanished,
        // so explicit lifecycle ownership never turns into an unbounded wait.
        await drainSendStream()
        try? connection.close(errorCode: 0, reason: Data())
    }

    private func drainSendStream() async {
        let sendStream = self.sendStream
        let connection = self.connection
        let timeout = self.closeDrainTimeout
        let clock = self.closeClock

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await sendStream.finish()
                _ = try? await sendStream.stopped()
            }
            group.addTask {
                do {
                    try await clock.sleep(for: timeout)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                try? connection.close(errorCode: 0, reason: Data())
            }
            await group.next()
            group.cancelAll()
        }
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

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
