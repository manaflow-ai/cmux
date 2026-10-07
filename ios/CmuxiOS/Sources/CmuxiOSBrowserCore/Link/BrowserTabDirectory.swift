public import CmuxiOSFeatureKit

/// The browser tab records of a host (owner: that host's workspace store).
/// C5's workspace mirror implements it; the browser source only reads it.
public protocol BrowserTabDirectory: Sendable {
    func tabs(on hostID: HostID) async -> AsyncStream<SourceSnapshot<[BrowserTabInfo]>>
}
