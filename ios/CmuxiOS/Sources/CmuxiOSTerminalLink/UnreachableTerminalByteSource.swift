import CmuxTerminalLink
public import CmuxTerminalRenderCore
public import CmuxTerminalStream
public import Foundation

/// A terminal whose Mac no carrier reaches: the screen shows why instead of
/// a blank surface, and input is refused (nothing queues offline).
public final class UnreachableTerminalByteSource: TerminalByteSource {
    public let terminalID: String
    public let reason: String

    public init(terminalID: String, reason: String) {
        self.terminalID = terminalID
        self.reason = reason
    }

    public var authority: TerminalAuthority { .host }

    public func open(_ viewport: TerminalViewport) async throws -> AsyncStream<TerminalSourceEvent> {
        let reason = reason
        return AsyncStream { continuation in
            continuation.yield(.closed(reason: reason))
            continuation.finish()
        }
    }

    public func send(_ input: Data) async throws { throw TerminalLinkError.notConnected }
    public func viewportChanged(_ viewport: TerminalViewport) async {}
    public func requestSnapshot(_ request: SnapshotRequest) async throws {}
    public func close() async {}
}
