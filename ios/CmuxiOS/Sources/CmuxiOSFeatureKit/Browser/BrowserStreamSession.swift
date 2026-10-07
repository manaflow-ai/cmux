import Foundation

/// One attached browser tab. The video track is rendered by lane C2 from
/// `CmuxLink`'s media handle; this seam carries state, input and navigation.
public protocol BrowserStreamSession: Sendable {
    var tabID: BrowserTabInfo.ID { get }
    func states() async -> AsyncStream<BrowserStreamState>
    func send(_ input: BrowserInput) async
    func navigate(_ navigation: BrowserNavigation, key: IntentKey) async throws -> IntentReceipt
    func close() async
}
