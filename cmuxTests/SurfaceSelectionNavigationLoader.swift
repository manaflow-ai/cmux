import AppKit
import Foundation
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

enum SurfaceSelectionTestError: Error {
    case expectedSnapshot
    case navigationFailed(String)
}

@MainActor
final class SurfaceSelectionNavigationLoader {
    private var continuation: CheckedContinuation<Void, any Error>?
    private weak var navigationDelegate: BrowserNavigationDelegate?
    private var previousDidFinish: ((WKWebView) -> Void)?
    private var previousDidFailNavigation: ((WKWebView, String, String, WKNavigation?) -> Void)?

    func load(
        _ html: String,
        baseURL: URL,
        in webView: WKWebView
    ) async throws {
        guard let navigationDelegate = webView.navigationDelegate as? BrowserNavigationDelegate else {
            throw SurfaceSelectionTestError.navigationFailed("Browser navigation delegate unavailable")
        }
        self.navigationDelegate = navigationDelegate
        previousDidFinish = navigationDelegate.didFinish
        previousDidFailNavigation = navigationDelegate.didFailNavigation
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            navigationDelegate.didFinish = { [weak self, weak webView] finishedWebView in
                self?.previousDidFinish?(finishedWebView)
                guard finishedWebView === webView else { return }
                self?.finish(with: .success(()))
            }
            navigationDelegate.didFailNavigation = {
                [weak self, weak webView] failedWebView, failedURL, message, navigation in
                self?.previousDidFailNavigation?(failedWebView, failedURL, message, navigation)
                guard failedWebView === webView else { return }
                self?.finish(with: .failure(
                    SurfaceSelectionTestError.navigationFailed(message)
                ))
            }
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    private func finish(with result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        navigationDelegate?.didFinish = previousDidFinish
        navigationDelegate?.didFailNavigation = previousDidFailNavigation
        navigationDelegate = nil
        previousDidFinish = nil
        previousDidFailNavigation = nil
        continuation.resume(with: result)
    }
}
