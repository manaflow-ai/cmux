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

extension BrowserHistoryEntry {
    /// A new tab's blank first page, which the phone shows as its Start
    /// Page. Safari never lists a raw "about:blank": the menu calls it
    /// Start Page (Back really goes there).
    var isStartPage: Bool { url.isEmpty || url == "about:blank" || url.hasPrefix("chrome://newtab") }

    /// The row's title line: the page title, "Start Page", or the address.
    var menuTitle: String { isStartPage ? "Start Page" : (title.isEmpty ? menuAddress : title) }

    /// The address line under the title (none for the start page or when
    /// the title already is the address).
    var menuSubtitle: String? { isStartPage || title.isEmpty ? nil : menuAddress }

    /// The address line of a history menu row, as Safari shows it: no
    /// scheme, no "www.", no trailing slash.
    var menuAddress: String {
        var s = url
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
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
