import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


private final class BrowserPanelTestScriptMessageHandler: NSObject, WKScriptMessageHandler {
    let expectation: XCTestExpectation
    var body: Any?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        body = message.body
        expectation.fulfill()
    }
}

@MainActor
final class BrowserPanelDiffViewerSchemeTests: XCTestCase {
    private func trustedDiffViewerTestRoot() -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func testDiffViewerSchemeRegistrationIsIdempotentForCopiedConfiguration() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            CmuxDiffViewerURLSchemeHandler.shared,
            forURLScheme: CmuxDiffViewerURLSchemeHandler.scheme
        )

        BrowserPanel.configureWebViewConfiguration(
            config,
            websiteDataStore: .nonPersistent()
        )

        XCTAssertNotNil(config.urlSchemeHandler(forURLScheme: CmuxDiffViewerURLSchemeHandler.scheme))
    }

    func testDiffViewerSchemeLoadsSameOriginModuleFromAllowlist() throws {
        let token = UUID().uuidString.lowercased()
        let rootURL = trustedDiffViewerTestRoot()
        let assetURL = rootURL
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("mod.mjs", isDirectory: false)
        let workerAssetURL = rootURL
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("worker.js", isDirectory: false)
        let indexURL = rootURL.appendingPathComponent("index.html", isDirectory: false)
        try FileManager.default.createDirectory(at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try """
        export const marker = "module-ok";
        """.write(to: assetURL, atomically: true, encoding: .utf8)
        try """
        export const workerMarker = "js-ok";
        """.write(to: workerAssetURL, atomically: true, encoding: .utf8)
        try """
        <!doctype html>
        <html>
        <body>
        <script type="module">
          import { marker } from "./assets/mod.mjs";
          import { workerMarker } from "./assets/worker.js";
          WebAssembly.compile(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]))
            .then(() => {
              const result = `${marker}:${workerMarker}:wasm-ok`;
              document.body.dataset.loaded = result;
              window.webkit.messageHandlers.moduleLoaded.postMessage(result);
            })
            .catch((error) => {
              const result = `wasm-error:${error.message}`;
              document.body.dataset.loaded = result;
              window.webkit.messageHandlers.moduleLoaded.postMessage(result);
            });
        </script>
        </body>
        </html>
        """.write(to: indexURL, atomically: true, encoding: .utf8)
        let patchURL = rootURL.appendingPathComponent("index.patch", isDirectory: false)
        try "diff --git a/a b/a\n".write(to: patchURL, atomically: true, encoding: .utf8)

        try CmuxDiffViewerURLSchemeHandler.shared.register(
            token: token,
            files: [
                .init(requestPath: "/index.html", fileURL: indexURL, mimeType: "text/html"),
                .init(requestPath: "/assets/mod.mjs", fileURL: assetURL, mimeType: "text/javascript"),
                .init(requestPath: "/assets/worker.js", fileURL: workerAssetURL, mimeType: "text/javascript"),
                .init(requestPath: "/index.patch", fileURL: patchURL, mimeType: "text/x-diff"),
            ]
        )

        let allowedURL = try XCTUnwrap(URL(string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://\(token)/index.html"))
        let allowedPatchURL = try XCTUnwrap(URL(string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://\(token)/index.patch"))
        let blockedURL = try XCTUnwrap(URL(string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://\(token)/not-allowed.html"))
        let queryURL = try XCTUnwrap(URL(string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://\(token)/index.html?copy=1"))
        XCTAssertNotNil(CmuxDiffViewerURLSchemeHandler.shared.registeredFile(for: allowedURL))
        XCTAssertNotNil(CmuxDiffViewerURLSchemeHandler.shared.registeredFile(for: allowedPatchURL))
        XCTAssertNil(CmuxDiffViewerURLSchemeHandler.shared.registeredFile(for: blockedURL))
        XCTAssertNil(CmuxDiffViewerURLSchemeHandler.shared.registeredFile(for: queryURL))

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        let moduleLoaded = expectation(description: "module evaluated")
        let moduleHandler = BrowserPanelTestScriptMessageHandler(expectation: moduleLoaded)
        contentController.add(moduleHandler, name: "moduleLoaded")
        config.userContentController = contentController
        config.setURLSchemeHandler(
            CmuxDiffViewerURLSchemeHandler.shared,
            forURLScheme: CmuxDiffViewerURLSchemeHandler.scheme
        )
        defer {
            contentController.removeScriptMessageHandler(forName: "moduleLoaded")
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        let loaded = expectation(description: "diff viewer loaded")
        let delegate = BrowserPanelTestNavigationDelegate(expectation: loaded)
        webView.navigationDelegate = delegate
        webView.load(URLRequest(url: allowedURL))
        wait(for: [loaded], timeout: 3)
        XCTAssertNil(delegate.error)
        wait(for: [moduleLoaded], timeout: 3)
        XCTAssertEqual(moduleHandler.body as? String, "module-ok:js-ok:wasm-ok")

        let evaluated = expectation(description: "module evaluated")
        webView.evaluateJavaScript("document.body.dataset.loaded || ''") { value, error in
            XCTAssertNil(error)
            XCTAssertEqual(value as? String, "module-ok:js-ok:wasm-ok")
            evaluated.fulfill()
        }
        wait(for: [evaluated], timeout: 3)
    }

    func testDiffViewerSchemeRejectsSymlinkEscapeFromTrustedRoot() throws {
        let token = UUID().uuidString.lowercased()
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-diff-viewer-security-\(UUID().uuidString)", isDirectory: true)
        let trustedRootURL = trustedDiffViewerTestRoot()
        let outsideURL = temporaryURL.appendingPathComponent("outside.html", isDirectory: false)
        let linkURL = trustedRootURL.appendingPathComponent("link.html", isDirectory: false)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trustedRootURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: trustedRootURL)
        }

        try "<!doctype html>".write(to: outsideURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)

        XCTAssertThrowsError(try CmuxDiffViewerURLSchemeHandler.shared.register(
            token: token,
            files: [
                .init(requestPath: "/link.html", fileURL: linkURL, mimeType: "text/html"),
            ]
        ))
    }

    func testDiffViewerSchemeRejectsMismatchedPatchMimeType() throws {
        let token = UUID().uuidString.lowercased()
        let trustedRootURL = trustedDiffViewerTestRoot()
        let patchURL = trustedRootURL.appendingPathComponent("diff.patch", isDirectory: false)
        try FileManager.default.createDirectory(at: trustedRootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: trustedRootURL) }

        try "diff --git a/a b/a\n".write(to: patchURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try CmuxDiffViewerURLSchemeHandler.shared.register(
            token: token,
            files: [
                .init(requestPath: "/diff.patch", fileURL: patchURL, mimeType: "text/html"),
            ]
        ))
    }
}


