import Foundation
import WebKit

/// Records WebKit's public navigation commands without starting a network request.
@MainActor
final class BrowserReloadRecordingWebView: WKWebView {
    var reportedURL: URL?
    var requests: [URLRequest] = []
    private(set) var reloadCount = 0
    private(set) var originReloadCount = 0

    override var url: URL? { reportedURL }

    override func load(_ request: URLRequest) -> WKNavigation? {
        requests.append(request)
        return nil
    }

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        nil
    }

    override func reload() -> WKNavigation? {
        reloadCount += 1
        return nil
    }

    override func reloadFromOrigin() -> WKNavigation? {
        originReloadCount += 1
        return nil
    }
}
