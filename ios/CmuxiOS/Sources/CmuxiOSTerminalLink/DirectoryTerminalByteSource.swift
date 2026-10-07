public import CmuxiOSFeatureKit
public import CmuxTerminalLink
public import CmuxTerminalRenderCore
public import CmuxTerminalStream
public import Foundation

/// A workspace terminal whose Mac link resolves when it opens: the screen
/// can be pushed before the account's link directory knows the Mac, and a
/// Mac no carrier reaches ends the stream with the reason instead of a
/// blank surface. Everything else forwards to `LinkTerminalByteSource`.
public final class DirectoryTerminalByteSource: TerminalByteSource, TerminalConnectionReporting, TerminalHistoryLoading {
    public let terminalID: String
    public let hostID: HostID
    private let resolved: Task<LinkTerminalByteSource?, Never>
    private let unreachable: String

    @MainActor
    public init(host: HostID, terminal: String, directory: any MobileLinkDirectory, options: TerminalLinkOptions,
                unreachable: String, describe: @escaping @Sendable (TerminalLinkFailure) -> String) {
        terminalID = terminal
        hostID = host
        self.unreachable = unreachable
        resolved = Task { @MainActor [weak directory] in
            guard let client = await directory?.client(for: host) else { return nil }
            return LinkTerminalByteSource(terminal: terminal, client: client, options: options, describe: describe)
        }
    }

    public var authority: TerminalAuthority { .host }

    public func open(_ viewport: TerminalViewport) async throws -> AsyncStream<TerminalSourceEvent> {
        guard let source = await resolved.value else {
            let reason = unreachable
            return AsyncStream { continuation in
                continuation.yield(.closed(reason: reason))
                continuation.finish()
            }
        }
        return try await source.open(viewport)
    }

    public func send(_ input: Data) async throws {
        guard let source = await resolved.value else { throw TerminalLinkError.notConnected }
        try await source.send(input)
    }

    public func viewportChanged(_ viewport: TerminalViewport) async {
        await resolved.value?.viewportChanged(viewport)
    }

    public func requestSnapshot(_ request: SnapshotRequest) async throws {
        try await resolved.value?.requestSnapshot(request)
    }

    public func close() async {
        await resolved.value?.close()
    }

    public func connectionStates() async -> AsyncStream<TerminalConnectionState> {
        guard let source = await resolved.value else {
            return AsyncStream { $0.yield(.offline); $0.finish() }
        }
        return await source.connectionStates()
    }

    public func loadOlderHistory() async {
        await resolved.value?.loadOlderHistory()
    }

    public func historyStates() async -> AsyncStream<TerminalHistoryState> {
        guard let source = await resolved.value else {
            return AsyncStream { $0.yield(.unavailable); $0.finish() }
        }
        return await source.historyStates()
    }
}
