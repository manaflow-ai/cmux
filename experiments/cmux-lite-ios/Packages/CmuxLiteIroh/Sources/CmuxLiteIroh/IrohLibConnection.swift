import Foundation
import IrohLib

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
    private let stateLock = NSLock()
    private var closed = false

    init(
        connection: Connection,
        stream: BiStream,
        maximumReceiveChunkBytes: UInt32
    ) {
        self.connection = connection
        sendStream = stream.send()
        receiveStream = stream.recv()
        self.maximumReceiveChunkBytes = maximumReceiveChunkBytes
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

        // Finish before closing the QUIC connection so a caller that has
        // explicitly awaited the stream's close observes an ordered FIN. The
        // acknowledgement wait belongs in a later, cancellable native slice;
        // this first provider keeps shutdown bounded when the peer vanished.
        try? await sendStream.finish()
        try? connection.close(errorCode: 0, reason: Data())
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
