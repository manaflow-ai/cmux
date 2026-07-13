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

        let insecureResponse = try #require(HTTPURLResponse(
            url: try #require(URL(string: "http://popup.example/report")),
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

        let extensionResponse = try #require(HTTPURLResponse(
            url: try #require(URL(string: "webkit-extension://example/export")),
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
