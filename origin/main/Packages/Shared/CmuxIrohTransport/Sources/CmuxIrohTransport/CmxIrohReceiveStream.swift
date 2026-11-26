public import Foundation

/// The readable half of one Iroh QUIC stream.
public protocol CmxIrohReceiveStream: Sendable {
    /// Reads at most the requested number of bytes.
    ///
    /// - Parameter maximumByteCount: A positive per-read bound.
    /// - Returns: Bytes, or `nil` after a clean peer finish.
    /// - Throws: A transport error or `CancellationError`.
    func receive(maximumByteCount: Int) async throws -> Data?

    /// Tells the peer to stop sending this stream.
    ///
    /// - Parameter errorCode: The application error code carried by QUIC.
    func stop(errorCode: UInt64) async
}
