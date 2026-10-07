import Foundation

/// Seam for lane C2 (browser streaming). `tabs(on:)` mirrors the browser tab
/// records of a host's workspace store; `open` attaches to one tab's video
/// and input over `CmuxLink`.
public protocol BrowserStreamSource: Sendable {
    func tabs(on hostID: HostID) async -> AsyncStream<SourceSnapshot<[BrowserTabInfo]>>
    func open(_ tabID: BrowserTabInfo.ID, on hostID: HostID) async throws -> any BrowserStreamSession
}
