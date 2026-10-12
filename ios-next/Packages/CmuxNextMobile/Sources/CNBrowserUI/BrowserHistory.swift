import CNCore
import CNTransport
import Foundation

/// What the toolbar's back | forward capsule shows and accepts for a tab.
/// Platform neutral so the rules are unit-tested (the toolbar reads them).
struct BackForwardState: Equatable, Sendable {
    /// The back circle (or back | forward capsule) is on screen.
    var visible: Bool
    var backEnabled: Bool
    /// Forward history exists: the capsule splits and forward takes taps.
    var forwardShown: Bool

    /// `local`: a terminal or Mac-only tab (no history). `sidesVisible`:
    /// the bar is expanded (the collapsed pill hides the side controls).
    init(tab: BrowserTab?, local: Bool, sidesVisible: Bool, editing: Bool) {
        visible = !local && sidesVisible && !editing
        backEnabled = visible && tab?.canGoBack == true
        forwardShown = !local && tab?.canGoForward == true
    }
}

/// A toolbar history step and the RPC it sends.
enum BrowserHistoryStep: Sendable {
    case back, forward

    var method: HostMethod { self == .back ? .browserBack : .browserForward }
    var verb: String { self == .back ? "go back" : "go forward" }

    /// `browser.back` / `browser.forward {tabId}`.
    func send(_ tabId: String, on client: HostClient) async throws {
        switch self {
        case .back: try await client.goBack(tabId)
        case .forward: try await client.goForward(tabId)
        }
    }
}

#if os(iOS)
extension BrowserModel {
    /// The toast for a refused create (`what`: "a new tab", "a terminal");
    /// the grid or page stays as it was.
    nonisolated static func createFailureNotice(_ what: String, _ error: any Error) -> String {
        if let rpc = error as? RPCError, rpc.code == .unsupported {
            return "Couldn't open \(what): this Mac doesn't allow it from iPhone yet."
        }
        return "Couldn't open \(what): \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
    }
}
#endif
