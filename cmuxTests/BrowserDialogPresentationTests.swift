import XCTest
import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Network

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Insecure HTTP alert and JavaScript dialog presentation
@MainActor
final class BrowserInsecureHTTPAlertPresentationTests: XCTestCase {
    private final class BrowserInsecureHTTPAlertSpy: NSAlert {
        private(set) var beginSheetModalCallCount = 0
        private(set) var runModalCallCount = 0
        var nextResponse: NSApplication.ModalResponse = .alertThirdButtonReturn

        override func beginSheetModal(
            for sheetWindow: NSWindow,
            completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
        ) {
            beginSheetModalCallCount += 1
            handler?(nextResponse)
        }

        override func runModal() -> NSApplication.ModalResponse {
            runModalCallCount += 1
            return nextResponse
        }
    }

    func testInsecureHTTPPromptUsesSheetWhenWindowIsAvailable() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.resetInsecureHTTPAlertHooksForTesting() }

        let alertSpy = BrowserInsecureHTTPAlertSpy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        panel.configureInsecureHTTPAlertHooksForTesting(
            alertFactory: { alertSpy },
            windowProvider: { window }
        )
        panel.presentInsecureHTTPAlertForTesting(url: URL(string: "http://example.com")!)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 1)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
    }

    func testInsecureHTTPPromptFallsBackToRunModalWithoutWindow() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.resetInsecureHTTPAlertHooksForTesting() }

        let alertSpy = BrowserInsecureHTTPAlertSpy()
        panel.configureInsecureHTTPAlertHooksForTesting(
            alertFactory: { alertSpy },
            windowProvider: { nil }
        )
        panel.presentInsecureHTTPAlertForTesting(url: URL(string: "http://example.com")!)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 0)
        XCTAssertEqual(alertSpy.runModalCallCount, 1)
    }

    func testInsecureHTTPPromptDefersWhileBackgroundPreloadHasNoInteractiveHost() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            preloadInitialNavigationInBackground: true,
            isRemoteWorkspace: false
        )
        defer {
            panel.resetInsecureHTTPAlertHooksForTesting()
            panel.close()
        }

        XCTAssertTrue(panel.hasBackgroundPreloadHost)
        XCTAssertNil(browserInteractiveModalHostWindow(for: panel.webView))

        let alertSpy = BrowserInsecureHTTPAlertSpy()
        panel.configureInsecureHTTPAlertHooksForTesting(
            alertFactory: { alertSpy },
            windowProvider: {
                XCTFail("Background preload should not prompt on fallback windows")
                return nil
            }
        )
        panel.presentInsecureHTTPAlertForTesting(url: URL(string: "http://example.com")!)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 0)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
    }
}


@MainActor
final class BrowserJavaScriptDialogDelegateTests: XCTestCase {
    func testBrowserPanelUIDelegateImplementsJavaScriptDialogSelectors() {
        let panel = BrowserPanel(workspaceId: UUID())
        guard let uiDelegate = panel.webView.uiDelegate as? NSObject else {
            XCTFail("Expected BrowserPanel webView.uiDelegate to be an NSObject")
            return
        }

        XCTAssertTrue(
            uiDelegate.responds(
                to: #selector(
                    WKUIDelegate.webView(
                        _:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:
                    )
                )
            ),
            "Browser UI delegate must implement JavaScript alert handling"
        )
        XCTAssertTrue(
            uiDelegate.responds(
                to: #selector(
                    WKUIDelegate.webView(
                        _:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:
                    )
                )
            ),
            "Browser UI delegate must implement JavaScript confirm handling"
        )
        XCTAssertTrue(
            uiDelegate.responds(
                to: #selector(
                    WKUIDelegate.webView(
                        _:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:
                    )
                )
            ),
            "Browser UI delegate must implement JavaScript prompt handling"
        )
    }
}


