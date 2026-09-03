public import Foundation

/// An ordered, reliable byte stream used beneath the cmux-lite protocol.
///
/// A receive result is an arbitrary chunk. It does not correspond to a
/// ``WireMessage`` or frame boundary. Returning `nil` means clean end-of-stream.
/// Implementations must make ``close()`` idempotent and unblock a pending
/// ``receive()``. One send and one receive may run concurrently. The session
/// owner serializes calls within each direction, so implementations may reject
/// overlapping sends or overlapping receives.
public protocol ByteStream: Sendable {
    /// Establishes the stream.
    ///
    /// Repeated calls after a successful connection must return successfully.
    ///
    /// - Throws: A transport-specific error or `CancellationError`.
    func connect() async throws

    /// Sends all bytes in one ordered write operation.
    ///
    /// An empty value is a no-op. Returning successfully means the
    /// implementation accepted the complete value for delivery, not that the
    /// peer processed it.
    ///
    /// - Parameter bytes: The bytes to enqueue for delivery.
    /// - Throws: A transport-specific error or `CancellationError`.
    func send(_ bytes: Data) async throws

    /// Receives the next available byte chunk.
    ///
    /// - Returns: The next non-empty chunk, or `nil` after clean end-of-stream.
    /// - Throws: A transport-specific error or `CancellationError`.
    func receive() async throws -> Data?

    /// Closes the stream and releases its transport resources.
    ///
    /// Repeated calls have no effect. A pending ``receive()`` resumes with
    /// `nil`.
    func close() async
}
