import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct BrowserWebExtensionPopoutPolicyTests {
    @MainActor
    @Test
    @available(macOS 15.4, *)
    func extensionRequestedFrameIsClampedToVisibleScreen() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 800, height: 600)
        let resolvedFrame = BrowserWebExtensionPopoutWindowController.resolvedContentFrame(
            requestedFrame: CGRect(x: -10_000, y: 10_000, width: 1_000_000, height: 1_000_000),
            visibleFrame: visibleFrame
        )

        #expect(resolvedFrame == visibleFrame)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func popoutAcceptsExactlyOneNewURLAndNoExistingTabs() {
        #expect(BrowserWebExtensionPopoutWindowController.supportsInitialTabs(
            urlCount: 1,
            existingTabCount: 0
        ))
        #expect(!BrowserWebExtensionPopoutWindowController.supportsInitialTabs(
            urlCount: 0,
            existingTabCount: 0
        ))
        #expect(!BrowserWebExtensionPopoutWindowController.supportsInitialTabs(
            urlCount: 2,
            existingTabCount: 0
        ))
        #expect(!BrowserWebExtensionPopoutWindowController.supportsInitialTabs(
            urlCount: 1,
            existingTabCount: 1
        ))
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func actionDownloadPolicyRequiresSafeURLAndSubframeIntent() throws {
        let secureURL = try #require(URL(string: "https://popup.example/export"))
        #expect(BrowserWebExtensionPopoutWindowController.actionDownloadPolicy(
            for: secureURL,
            isForMainFrame: false,
            hasUserActivation: false,
            hasRecordedIntent: false,
            blocksInsecureHTTP: false
        ) == .cancel)
        #expect(BrowserWebExtensionPopoutWindowController.actionDownloadPolicy(
            for: secureURL,
            isForMainFrame: false,
            hasUserActivation: true,
            hasRecordedIntent: false,
            blocksInsecureHTTP: false
        ) == .download)
        #expect(BrowserWebExtensionPopoutWindowController.actionDownloadPolicy(
            for: secureURL,
            isForMainFrame: true,
            hasUserActivation: false,
            hasRecordedIntent: false,
            blocksInsecureHTTP: false
        ) == .download)

        let insecureURL = try #require(URL(string: "http://popup.example/export"))
        #expect(BrowserWebExtensionPopoutWindowController.actionDownloadPolicy(
            for: insecureURL,
            isForMainFrame: true,
            hasUserActivation: true,
            hasRecordedIntent: true,
            blocksInsecureHTTP: true
        ) == .cancel)

        let externalURL = try #require(URL(string: "custom-download://export"))
        #expect(BrowserWebExtensionPopoutWindowController.actionDownloadPolicy(
            for: externalURL,
            isForMainFrame: true,
            hasUserActivation: true,
            hasRecordedIntent: true,
            blocksInsecureHTTP: false
        ) == .cancel)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func externalFallbackAcceptsOnlyPlainGetRequests() throws {
        let url = try #require(URL(string: "https://popup.example/login"))
        let plainRequest = URLRequest(url: url)
        #expect(!Workspace.BrowserPanelCreationPolicy.extensionRequested.opensExternallyWhenBrowserDisabled)
        #expect(BrowserWebExtensionPopoutWindowController.canFallbackToExternalBrowser(for: plainRequest))

        var authenticatedRequest = plainRequest
        authenticatedRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        #expect(!BrowserWebExtensionPopoutWindowController.canFallbackToExternalBrowser(for: authenticatedRequest))

        var postRequest = plainRequest
        postRequest.httpMethod = "POST"
        postRequest.httpBody = Data("credential=secret".utf8)
        #expect(!BrowserWebExtensionPopoutWindowController.canFallbackToExternalBrowser(for: postRequest))
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func uiDelegateRoutesDOMCloseAndNewWindowRequests() throws {
        var didClose = false
        var routedRequest: URLRequest?
        let delegate = BrowserWebExtensionPopoutUIDelegate(
            closeAction: { didClose = true },
            newWindowAction: { routedRequest = $0 }
        )

        delegate.webViewDidClose(WKWebView())
        #expect(didClose)

        let url = try #require(URL(string: "https://popup.example/submit"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("credential=secret".utf8)
        request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        delegate.handleNewWindowRequest(request)

        #expect(routedRequest?.url == url)
        #expect(routedRequest?.httpMethod == "POST")
        #expect(routedRequest?.httpBody == request.httpBody)
        #expect(routedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func uiDelegateReturnsScriptedChildUsingSuppliedConfiguration() {
        let suppliedConfiguration = WKWebViewConfiguration()
        let windowFeatures = WKWindowFeatures()
        let expectedWebView = WKWebView(frame: .zero, configuration: suppliedConfiguration)
        var receivedConfiguration: WKWebViewConfiguration?
        let delegate = BrowserWebExtensionPopoutUIDelegate(
            scriptedPopupAction: { configuration, features in
                receivedConfiguration = configuration
                #expect(features === windowFeatures)
                return expectedWebView
            }
        )

        let returnedWebView = delegate.createScriptedPopup(
            configuration: suppliedConfiguration,
            windowFeatures: windowFeatures
        )

        #expect(returnedWebView === expectedWebView)
        #expect(receivedConfiguration === suppliedConfiguration)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func uiDelegateAttributesDialogsToInitiatingFrameURL() throws {
        let delegate = BrowserWebExtensionPopoutUIDelegate()
        let topLevelURL = try #require(URL(string: "webkit-extension://trusted/popup.html"))
        let frameURL = try #require(URL(string: "https://iframe.example/dialog"))

        let topLevelTitle = delegate.javaScriptDialogTitle(for: topLevelURL)
        let frameTitle = delegate.javaScriptDialogTitle(for: frameURL)

        #expect(frameTitle.contains(frameURL.absoluteString))
        #expect(!frameTitle.contains(topLevelURL.absoluteString))
        #expect(frameTitle != topLevelTitle)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func responsePolicyConvertsSafeDownloadResponses() throws {
        let attachmentURL = try #require(URL(string: "https://popup.example/report"))
        let attachmentResponse = try #require(HTTPURLResponse(
            url: attachmentURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Disposition": "attachment; filename=report.html",
                "Content-Type": "text/html",
            ]
        ))
        #expect(BrowserWebExtensionPopoutWindowController.responsePolicy(
            for: attachmentResponse,
            canShowMIMEType: true,
            isForMainFrame: true,
            allowsSubframeDownload: true,
            blocksInsecureHTTP: false
        ) == .download)
        #expect(BrowserWebExtensionPopoutWindowController.responsePolicy(
            for: attachmentResponse,
            canShowMIMEType: true,
            isForMainFrame: false,
            allowsSubframeDownload: false,
            blocksInsecureHTTP: false
        ) == .cancel)
        #expect(BrowserWebExtensionPopoutWindowController.responsePolicy(
            for: attachmentResponse,
            canShowMIMEType: true,
            isForMainFrame: false,
            allowsSubframeDownload: true,
            blocksInsecureHTTP: false
        ) == .download)

        let unsupportedResponse = URLResponse(
            url: attachmentURL,
            mimeType: "application/x-extension-export",
            expectedContentLength: 100,
            textEncodingName: nil
        )
        #expect(BrowserWebExtensionPopoutWindowController.responsePolicy(
            for: unsupportedResponse,
            canShowMIMEType: false,
            isForMainFrame: true,
            allowsSubframeDownload: true,
            blocksInsecureHTTP: false
        ) == .download)

        let insecureURL = try #require(URL(string: "http://popup.example/report"))
        let insecureResponse = try #require(HTTPURLResponse(
            url: insecureURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Disposition": "attachment"]
        ))
        #expect(BrowserWebExtensionPopoutWindowController.responsePolicy(
            for: insecureResponse,
            canShowMIMEType: true,
            isForMainFrame: false,
            allowsSubframeDownload: true,
            blocksInsecureHTTP: true
        ) == .cancel)

        let extensionURL = try #require(URL(string: "webkit-extension://example/export"))
        let extensionResponse = try #require(HTTPURLResponse(
            url: extensionURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Disposition": "attachment"]
        ))
        #expect(BrowserWebExtensionPopoutWindowController.responsePolicy(
            for: extensionResponse,
            canShowMIMEType: true,
            isForMainFrame: true,
            allowsSubframeDownload: true,
            blocksInsecureHTTP: false
        ) == .allow)
    }
}
