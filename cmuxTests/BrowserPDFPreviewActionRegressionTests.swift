import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct BrowserPDFPreviewActionRegressionTests {
    @Test func browserPanelUIDelegateRespondsToPDFPreviewDownloadSelector() throws {
        let panel = BrowserPanel(workspaceId: UUID())
        let delegate = try #require(panel.webView.uiDelegate as? NSObject)
        let selector = NSSelectorFromString("_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:")

        #expect(
            delegate.responds(to: selector),
            "WebKit checks this exact selector before delivering the PDF HUD download click; when the delegate does not respond, the button does nothing."
        )
    }

    @Test func browserPanelUIDelegateRespondsToPDFPreviewPrintSelector() throws {
        let panel = BrowserPanel(workspaceId: UUID())
        let delegate = try #require(panel.webView.uiDelegate as? NSObject)
        let selector = NSSelectorFromString("_webView:printFrame:pdfFirstPageSize:completionHandler:")

        #expect(
            delegate.responds(to: selector),
            "WebKit checks this exact selector before delivering the PDF HUD print click; when the delegate does not respond, the button does nothing."
        )
    }

    @Test func browserPanelUIDelegateGrantsUserActivatedPointerLockRequest() throws {
        let panel = BrowserPanel(workspaceId: UUID())
        let delegate = try #require(panel.webView.uiDelegate as? NSObject)
        let selector = NSSelectorFromString("_webViewDidRequestPointerLock:completionHandler:")

        #expect(
            delegate.responds(to: selector),
            "WebKit only asks the embedder to grant pointer lock when its UI delegate implements the private request callback."
        )
        guard let implementation = delegate.method(for: selector) else { return }

        var granted: Bool?
        typealias PointerLockFunction = @convention(c) (
            AnyObject,
            Selector,
            WKWebView,
            @convention(block) (Bool) -> Void
        ) -> Void
        let function = unsafeBitCast(implementation, to: PointerLockFunction.self)
        let completionBlock: @convention(block) (Bool) -> Void = { granted = $0 }
        function(delegate, selector, panel.webView, completionBlock)

        #expect(granted == true)
    }
}
