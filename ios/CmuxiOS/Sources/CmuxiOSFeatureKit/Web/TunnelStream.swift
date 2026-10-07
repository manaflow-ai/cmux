public import Foundation

/// One TCP byte stream to a port on another machine (lane C14): over a Mac's
/// `tcp.forward` channel or an SSH `direct-tcpip` channel. Every call
/// suspends until done, so a forwarder never reads ahead of a write.
public protocol TunnelStream: Sendable {
    /// The next bytes, or nil once the far end finished sending.
    func read() async throws -> Data?
    func write(_ data: Data) async throws
    /// Half close: no more bytes from this side.
    func finishWriting() async
    /// Ends both directions.
    func close() async
}
