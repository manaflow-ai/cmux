import Foundation

/// One attached browser tab (lane C2): video samples to decode, page
/// updates, input, navigation and viewport. Each stream has one consumer.
public protocol BrowserStreamSession: Sendable {
    var tabID: BrowserTabInfo.ID { get }
    func states() async -> AsyncStream<BrowserStreamState>
    func pageUpdates() async -> AsyncStream<BrowserPageUpdate>
    func videoSamples() async -> AsyncStream<BrowserVideoSample>
    func send(_ input: BrowserInput) async
    /// `.refused` carries the Mac's reason (`scheme` for non-http(s) URLs).
    func navigate(_ navigation: BrowserNavigation, key: IntentKey) async throws -> IntentReceipt
    func setViewport(_ viewport: BrowserViewport) async
    /// Pushes the phone's clipboard to the Mac right before a paste.
    func paste(_ text: String) async
    /// The decoder lost its reference: ask for a keyframe.
    func requestKeyframe() async
    func close() async
}
