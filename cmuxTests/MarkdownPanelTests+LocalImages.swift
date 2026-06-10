import AppKit
import Combine
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Local & Data Images
extension MarkdownPanelTests {
    func testMarkdownRenderHandlesLocalImageSources() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-image-\(UUID().uuidString)", isDirectory: true)
        let directoryURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let imageURL = directoryURL.appendingPathComponent("pixel.png")
        let outsideImageURL = rootURL.appendingPathComponent("outside.png")
        let markdownURL = directoryURL.appendingPathComponent("image.md")
        try Self.onePixelPNG.write(to: imageURL)
        try Self.onePixelPNG.write(to: outsideImageURL)
        try """
        ![Local pixel](pixel.png)
        ![Traversal pixel](../outside.png)
        ![Explicit file pixel](\(outsideImageURL.absoluteString))
        ![Root absolute pixel](\(outsideImageURL.path))
        """.write(to: markdownURL, atomically: true, encoding: .utf8)

        let frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let configuration = WKWebViewConfiguration()
        let coordinator = MarkdownWebRenderer.Coordinator()
        coordinator.filePath = markdownURL.path
        configuration.setURLSchemeHandler(coordinator, forURLScheme: MarkdownWebRenderer.localImageURLScheme)
        let webView = MarkdownWebView(frame: frame, configuration: configuration)
        coordinator.webView = webView
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            coordinator.webView = nil
            window.close()
        }

        let loaded = expectation(description: "markdown shell loaded")
        let loadDelegate = MarkdownShellLoadDelegate(expectation: loaded)
        webView.navigationDelegate = loadDelegate
        webView.loadHTMLString(
            MarkdownViewerAssets.shared.shellHTML(isDark: true),
            baseURL: markdownURL
        )
        await fulfillment(of: [loaded], timeout: 5)
        if let error = loadDelegate.error {
            throw error
        }
        defer { coordinator.cancelLocalImageLoads() }

        try await renderMarkdown(
            """
            ![Local pixel](pixel.png)
            ![Traversal pixel](../outside.png)
            ![Explicit file pixel](\(outsideImageURL.absoluteString))
            ![Root absolute pixel](\(outsideImageURL.path))
            """,
            in: webView
        )
        let images = try await waitForMarkdownImages(expectedCount: 4, in: webView)
        func image(alt: String) throws -> [String: Any] {
            try XCTUnwrap(images.first { $0["alt"] as? String == alt })
        }

        let localImage = try image(alt: "Local pixel")
        XCTAssertEqual(localImage["complete"] as? Bool, true)
        XCTAssertGreaterThan(try XCTUnwrap(localImage["naturalWidth"] as? Int), 0)
        XCTAssertGreaterThan(try XCTUnwrap(localImage["naturalHeight"] as? Int), 0)
        XCTAssertTrue((localImage["currentSrc"] as? String ?? "").hasPrefix("cmux-local-image://"))

        let traversalImage = try image(alt: "Traversal pixel")
        XCTAssertEqual(traversalImage["complete"] as? Bool, true)
        XCTAssertEqual(traversalImage["naturalWidth"] as? Int, 0)
        XCTAssertEqual(traversalImage["naturalHeight"] as? Int, 0)
        XCTAssertTrue((traversalImage["currentSrc"] as? String ?? "").hasPrefix("cmux-local-image://"))

        let explicitFileImage = try image(alt: "Explicit file pixel")
        XCTAssertEqual(explicitFileImage["src"] as? String, "")
        XCTAssertEqual(explicitFileImage["currentSrc"] as? String, "")

        let rootAbsoluteImage = try image(alt: "Root absolute pixel")
        XCTAssertEqual(rootAbsoluteImage["src"] as? String, "")
        XCTAssertEqual(rootAbsoluteImage["currentSrc"] as? String, "")
    }

    func testMarkdownRenderDeniesLocalImageWhenMarkdownPathIsMissing() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-missing-path-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let imageURL = rootURL.appendingPathComponent("outside.png")
        try Self.onePixelPNG.write(to: imageURL)

        var components = URLComponents()
        components.scheme = MarkdownWebRenderer.localImageURLScheme
        components.host = "image"
        components.queryItems = [URLQueryItem(name: "url", value: imageURL.absoluteString)]
        let localImageURL = try XCTUnwrap(components.url)

        let coordinator = MarkdownWebRenderer.Coordinator()
        defer { coordinator.cancelImageLoads() }

        let finished = expectation(description: "local image request finished")
        let task = MarkdownURLSchemeTaskSpy(
            request: URLRequest(url: localImageURL),
            finishedExpectation: finished
        )
        coordinator.webView(WKWebView(frame: .zero), start: task)

        await fulfillment(of: [finished], timeout: 2)
        let snapshot = task.snapshot()
        XCTAssertEqual(snapshot.responses.count, 1)
        XCTAssertEqual(snapshot.responses.first?.mimeType, "image/png")
        XCTAssertEqual(snapshot.data, Data())
        XCTAssertTrue(snapshot.didFinish)
        XCTAssertNil(snapshot.error)
    }

    func testMarkdownRenderLoadsSafeDataImage() async throws {
        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-data-image-\(UUID().uuidString).md")

        let frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            window.close()
        }

        let loaded = expectation(description: "markdown shell loaded")
        let loadDelegate = MarkdownShellLoadDelegate(expectation: loaded)
        webView.navigationDelegate = loadDelegate
        webView.loadHTMLString(
            MarkdownViewerAssets.shared.shellHTML(isDark: true),
            baseURL: markdownURL
        )
        await fulfillment(of: [loaded], timeout: 5)
        if let error = loadDelegate.error {
            throw error
        }

        try await renderMarkdown("![Inline pixel](\(Self.onePixelPNGDataURI))\n", in: webView)
        let image = try await waitForMarkdownImage(in: webView)

        XCTAssertEqual(image["found"] as? Bool, true)
        XCTAssertEqual(image["complete"] as? Bool, true)
        XCTAssertGreaterThan(try XCTUnwrap(image["naturalWidth"] as? Int), 0)
        XCTAssertGreaterThan(try XCTUnwrap(image["naturalHeight"] as? Int), 0)
        XCTAssertTrue((image["src"] as? String ?? "").hasPrefix("data:image/png;base64,"))
    }

    private func waitForMarkdownImage(in webView: WKWebView) async throws -> [String: Any] {
        let images = try await waitForMarkdownImages(expectedCount: 1, in: webView)
        return try XCTUnwrap(images.first)
    }

    private func waitForMarkdownImages(expectedCount: Int, in webView: WKWebView) async throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(3)
        var lastSnapshot: [[String: Any]] = []

        while Date() < deadline {
            let result = try await webView.evaluateJavaScript(
                """
                (function() {
                  return Array.prototype.slice.call(document.querySelectorAll('img')).map(function(img) {
                    return {
                      found: true,
                      alt: img.getAttribute('alt') || '',
                      complete: !!img.complete,
                      naturalWidth: img.naturalWidth || 0,
                      naturalHeight: img.naturalHeight || 0,
                      src: img.getAttribute('src') || '',
                      currentSrc: img.currentSrc || '',
                      hidden: !!img.hidden,
                      remoteSrc: img.getAttribute('data-cmux-remote-src') || ''
                    };
                  });
                })();
                """
            )
            lastSnapshot = try XCTUnwrap(result as? [[String: Any]])
            if lastSnapshot.count == expectedCount,
               lastSnapshot.allSatisfy({ $0["complete"] as? Bool == true }) {
                return lastSnapshot
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        throw NSError(
            domain: "MarkdownPanelTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Timed out waiting for markdown image to load. Last snapshot: \(lastSnapshot)"
            ]
        )
    }

    private static let onePixelPNG: Data = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Unable to generate one-pixel PNG fixture")
        }
        return png
    }()

    private static let onePixelPNGDataURI = "data:image/png;base64,\(onePixelPNG.base64EncodedString())"
}
