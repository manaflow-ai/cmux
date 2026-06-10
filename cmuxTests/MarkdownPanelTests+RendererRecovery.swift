import AppKit
import Combine
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Renderer Session & Recovery
extension MarkdownPanelTests {
    func testMarkdownRendererSessionReusesCoordinatorAcrossViewRecreation() {
        let session = MarkdownRendererSession()
        let panelId = UUID()
        let workspaceId = UUID()
        let filePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("stable-renderer.md")
            .path
        let theme = MarkdownWebTheme.resolve(backgroundColor: .windowBackgroundColor)

        let firstRenderer = MarkdownWebRenderer(
            markdown: "# Existing\n",
            theme: theme,
            backgroundColor: .windowBackgroundColor,
            panelId: panelId,
            workspaceId: workspaceId,
            filePath: filePath,
            fontSize: 15,
            fontFamily: MarkdownFontFamily.systemDefault,
            maxContentWidth: MarkdownMaxWidthSettings.defaultCSSPixels,
            session: session,
            onRequestPanelFocus: {}
        )
        let firstCoordinator = firstRenderer.makeCoordinator()

        let recreatedRenderer = MarkdownWebRenderer(
            markdown: "# Existing\n",
            theme: theme,
            backgroundColor: .windowBackgroundColor,
            panelId: panelId,
            workspaceId: workspaceId,
            filePath: filePath,
            fontSize: 15,
            fontFamily: MarkdownFontFamily.systemDefault,
            maxContentWidth: MarkdownMaxWidthSettings.defaultCSSPixels,
            session: session,
            onRequestPanelFocus: {}
        )
        let recreatedCoordinator = recreatedRenderer.makeCoordinator()

        XCTAssertTrue(
            firstCoordinator === recreatedCoordinator,
            "Markdown renderer should keep its coordinator across SwiftUI view recreation so existing previews do not reload and blink during drops."
        )
    }

    func testMarkdownRendererDismantleKeepsPointerHandlerForReusedWebView() {
        let coordinator = MarkdownWebRenderer.Coordinator()
        let reusedWebView = MarkdownWebView(frame: .zero, configuration: WKWebViewConfiguration())
        coordinator.webView = reusedWebView

        var reusedPointerDownCount = 0
        reusedWebView.onPointerDown = {
            reusedPointerDownCount += 1
        }

        MarkdownWebRenderer.dismantleNSView(reusedWebView, coordinator: coordinator)
        reusedWebView.onPointerDown?()

        XCTAssertEqual(
            reusedPointerDownCount,
            1,
            "SwiftUI teardown for an old renderer wrapper must not clear the pointer handler on the reused markdown web view."
        )

        let discardedWebView = MarkdownWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var discardedPointerDownCount = 0
        discardedWebView.onPointerDown = {
            discardedPointerDownCount += 1
        }

        MarkdownWebRenderer.dismantleNSView(discardedWebView, coordinator: coordinator)
        discardedWebView.onPointerDown?()

        XCTAssertEqual(discardedPointerDownCount, 0)
    }

    func testMarkdownRendererKeepsRecoveryBudgetAfterShellReload() {
        let coordinator = MarkdownWebRenderer.Coordinator()
        let webView = MarkdownWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let theme = MarkdownWebTheme.resolve(backgroundColor: .windowBackgroundColor)
        coordinator.webView = webView
        defer { coordinator.close() }

        coordinator.loadShell(theme: theme, initialMarkdown: "# Existing\n")
        coordinator.webViewWebContentProcessDidTerminate(webView)

        XCTAssertEqual(coordinator.webContentProcessRecoveryAttemptsForTesting, 1)
        XCTAssertTrue(coordinator.isShellLoadingForTesting)

        coordinator.webView(webView, didFinish: nil)

        XCTAssertEqual(coordinator.webContentProcessRecoveryAttemptsForTesting, 1)
        XCTAssertFalse(coordinator.isShellLoadingForTesting)
    }

    func testMarkdownRendererRestartsShellWhenContentChangesAfterRecoveryBudgetExhausted() {
        let coordinator = MarkdownWebRenderer.Coordinator()
        let webView = MarkdownWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let theme = MarkdownWebTheme.resolve(backgroundColor: .windowBackgroundColor)
        coordinator.webView = webView
        defer { coordinator.close() }

        coordinator.loadShell(theme: theme, initialMarkdown: "# Existing\n")
        for _ in 0...2 {
            coordinator.webViewWebContentProcessDidTerminate(webView)
        }

        XCTAssertEqual(coordinator.webContentProcessRecoveryAttemptsForTesting, 2)
        XCTAssertFalse(coordinator.isShellLoadingForTesting)

        coordinator.update(markdown: "# Replacement\n", theme: theme)

        XCTAssertEqual(coordinator.webContentProcessRecoveryAttemptsForTesting, 0)
        XCTAssertTrue(coordinator.isShellLoadingForTesting)
    }

    func testMarkdownRendererCapsRecoveryWhenPayloadCrashesAfterShellFinish() {
        let coordinator = MarkdownWebRenderer.Coordinator()
        let webView = MarkdownWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let theme = MarkdownWebTheme.resolve(backgroundColor: .windowBackgroundColor)
        coordinator.webView = webView
        defer { coordinator.close() }

        coordinator.loadShell(theme: theme, initialMarkdown: "# Existing\n")

        for expectedAttempt in 1...2 {
            coordinator.webViewWebContentProcessDidTerminate(webView)
            XCTAssertEqual(coordinator.webContentProcessRecoveryAttemptsForTesting, expectedAttempt)
            XCTAssertTrue(coordinator.isShellLoadingForTesting)

            coordinator.webView(webView, didFinish: nil)
            XCTAssertEqual(coordinator.webContentProcessRecoveryAttemptsForTesting, expectedAttempt)
        }

        coordinator.webViewWebContentProcessDidTerminate(webView)

        XCTAssertEqual(coordinator.webContentProcessRecoveryAttemptsForTesting, 2)
        XCTAssertFalse(coordinator.isShellLoadingForTesting)

        coordinator.update(markdown: "# Existing\n", theme: theme)

        XCTAssertEqual(coordinator.webContentProcessRecoveryAttemptsForTesting, 2)
        XCTAssertFalse(coordinator.isShellLoadingForTesting)
    }

    func testMarkdownRendererNavigationFailureUnblocksFutureShellReload() {
        let coordinator = MarkdownWebRenderer.Coordinator()
        let webView = MarkdownWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let theme = MarkdownWebTheme.resolve(backgroundColor: .windowBackgroundColor)
        coordinator.webView = webView
        defer { coordinator.close() }

        coordinator.loadShell(theme: theme, initialMarkdown: "# Existing\n")
        XCTAssertTrue(coordinator.isShellLoadingForTesting)

        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotLoadFromNetwork)
        coordinator.webView(webView, didFail: nil, withError: error)

        XCTAssertFalse(coordinator.isShellLoadingForTesting)

        coordinator.update(markdown: "# Replacement\n", theme: theme)

        XCTAssertTrue(coordinator.isShellLoadingForTesting)
    }

    func testMarkdownRendererNavigationFailureReloadsSameContentUpdate() {
        let coordinator = MarkdownWebRenderer.Coordinator()
        let webView = MarkdownWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let theme = MarkdownWebTheme.resolve(backgroundColor: .windowBackgroundColor)
        coordinator.webView = webView
        defer { coordinator.close() }

        coordinator.loadShell(theme: theme, initialMarkdown: "# Existing\n")
        coordinator.webView(webView, didFinish: nil)
        XCTAssertFalse(coordinator.isShellLoadingForTesting)

        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotLoadFromNetwork)
        coordinator.loadShell(theme: theme, initialMarkdown: "# Existing\n")
        coordinator.webView(webView, didFail: nil, withError: error)

        XCTAssertFalse(coordinator.isShellLoadingForTesting)

        coordinator.update(markdown: "# Existing\n", theme: theme)

        XCTAssertTrue(coordinator.isShellLoadingForTesting)
    }

}
