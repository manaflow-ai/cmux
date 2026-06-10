import AppKit
import Combine
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Remote Images
extension MarkdownPanelTests {
    func testMarkdownRenderBlocksRemoteImagesUntilUserAction() async throws {
        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-remote-image-\(UUID().uuidString).md")

        let frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        let configuration = WKWebViewConfiguration()
        let coordinator = MarkdownWebRenderer.Coordinator()
        let remoteImageHandler = MarkdownRemoteImageHoldingSchemeHandler()
        coordinator.filePath = markdownURL.path
        configuration.setURLSchemeHandler(coordinator, forURLScheme: MarkdownWebRenderer.localImageURLScheme)
        configuration.setURLSchemeHandler(remoteImageHandler, forURLScheme: MarkdownWebRenderer.remoteImageURLScheme)
        let webView = MarkdownWebView(frame: frame, configuration: configuration)
        coordinator.webView = webView
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            coordinator.webView = nil
            coordinator.cancelImageLoads()
            remoteImageHandler.cancelOpenTasks()
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

        let expectedBlockedTitle = String(
            localized: "markdown.web.remoteImageBlocked",
            defaultValue: "Remote image blocked"
        )
        let expectedConsentMessage = String(
            localized: "markdown.web.remoteImageConsentMessage",
            defaultValue: "cmux will not contact this image URL until you load this image."
        )
        let expectedLoadButton = String(
            localized: "markdown.web.remoteImageLoadImage",
            defaultValue: "Load this image"
        )
        let expectedLoadingButton = String(
            localized: "markdown.web.remoteImageLoading",
            defaultValue: "Loading"
        )
        let expectedCopyURLButton = String(
            localized: "markdown.web.remoteImageCopyURL",
            defaultValue: "Copy image URL"
        )
        let expectedCopiedButton = String(
            localized: "markdown.web.remoteImageCopied",
            defaultValue: "Copied"
        )
        let expectedOpenURLButton = String(
            localized: "markdown.web.remoteImageOpenURL",
            defaultValue: "Open image URL"
        )
        let expectedHTTPSOnlyMessage = String(
            localized: "markdown.web.remoteImageHTTPSOnly",
            defaultValue: "Only HTTPS remote images can be loaded in the viewer."
        )
        let expectedNotAllowedMessage = String(
            localized: "markdown.web.remoteImageNotAllowed",
            defaultValue: "This remote image URL cannot be loaded in the viewer."
        )
        func expectedURLText(_ url: String) -> String {
            String(
                localized: "markdown.web.remoteImageURL",
                defaultValue: "Image URL: {url}"
            ).replacingOccurrences(of: "{url}", with: url)
        }

        try await renderMarkdown(
            """
            Inline markdown file marker: `README.md`

            ```
            README.md
            ```

            <style>body { background-image: url(https://images.example.com/style.png); }</style>

            <table background="https://images.example.com/background.png"><tr><td background="https://images.example.com/cell.png">legacy background</td></tr></table>

            <details><summary>Visible details summary</summary>Hidden details text</details>

            ![HTTPS remote](https://images.example.com/pixel.png)
            [![Linked remote](https://images.example.com/linked.png)](README.md)
            ![Duplicate linked remote](https://images.example.com/linked.png)
            ![HTTP remote](http://images.example.com/pixel.png)
            ![Localhost remote](https://localhost/pixel.png)
            ![Credential remote](https://user:pass@images.example.com/secret.png)
            <img alt="Expanded IPv6 mapped remote" src="https://[0:0:0:0:0:ffff:7f00:1]/image.png">
            <img alt="Spoofed internal" data-cmux-remote-src="https%3A%2F%2Fspoof.example%2Fpixel.png">
            """,
            in: webView
        )

        let before = try await remoteImageSnapshot(in: webView)
        let beforeImages = try XCTUnwrap(before["images"] as? [[String: Any]])
        let beforePlaceholders = try XCTUnwrap(before["placeholders"] as? [String])
        let beforeURLs = try XCTUnwrap(before["remoteImageURLs"] as? [String])
        let beforeButtons = try XCTUnwrap(before["buttons"] as? [String])
        let beforeCodeFiles = try XCTUnwrap(before["codeFiles"] as? [String])
        let beforeStyleCount = try XCTUnwrap(before["styleCount"] as? Int)
        let beforeBackgroundAttrCount = try XCTUnwrap(before["backgroundAttrCount"] as? Int)
        let beforeRenderedText = try XCTUnwrap(before["renderedText"] as? String)
        XCTAssertEqual(beforeImages.count, 8)
        XCTAssertEqual(beforePlaceholders.count, 7)
        XCTAssertEqual(beforeURLs.count, 7)
        XCTAssertTrue(beforeURLs.contains(expectedURLText("https://images.example.com/pixel.png")))
        XCTAssertEqual(beforeURLs.filter { $0 == expectedURLText("https://images.example.com/linked.png") }.count, 2)
        XCTAssertTrue(beforeURLs.contains(expectedURLText("http://images.example.com/pixel.png")))
        XCTAssertTrue(beforeURLs.contains(expectedURLText("https://localhost/pixel.png")))
        XCTAssertTrue(beforeURLs.contains(expectedURLText("https://user:pass@images.example.com/secret.png")))
        XCTAssertTrue(beforeURLs.contains(expectedURLText("https://[::ffff:7f00:1]/image.png")))
        XCTAssertEqual(beforeButtons.filter { $0 == expectedLoadButton }.count, 3)
        XCTAssertEqual(beforeButtons.filter { $0 == expectedCopyURLButton }.count, 7)
        XCTAssertEqual(beforeButtons.filter { $0 == expectedOpenURLButton }.count, 7)
        XCTAssertEqual(beforeCodeFiles, ["README.md"])
        XCTAssertEqual(beforeStyleCount, 0)
        XCTAssertEqual(beforeBackgroundAttrCount, 0)
        XCTAssertFalse(beforeRenderedText.contains(expectedBlockedTitle))
        XCTAssertFalse(beforeRenderedText.contains(expectedLoadButton))
        XCTAssertFalse(beforeRenderedText.contains(expectedCopyURLButton))
        XCTAssertFalse(beforeRenderedText.contains(expectedOpenURLButton))
        XCTAssertTrue(beforeRenderedText.contains("Visible details summary"))
        XCTAssertFalse(beforeRenderedText.contains("Hidden details text"))
        let remoteManagedImages = beforeImages.filter { !((($0["remoteSrc"] as? String) ?? "").isEmpty) }
        XCTAssertEqual(remoteManagedImages.count, 7)
        for image in remoteManagedImages {
            XCTAssertEqual(image["src"] as? String, "")
            XCTAssertEqual(image["currentSrc"] as? String, "")
            XCTAssertEqual(image["hidden"] as? Bool, true)
            XCTAssertNotNil(image["remoteSrc"] as? String)
        }
        let spoofedImage = try XCTUnwrap(beforeImages.first { $0["alt"] as? String == "Spoofed internal" })
        XCTAssertEqual(spoofedImage["remoteSrc"] as? String, "")
        XCTAssertEqual(spoofedImage["hidden"] as? Bool, false)
        XCTAssertTrue(beforePlaceholders.contains { $0.contains(expectedConsentMessage) })
        XCTAssertTrue(beforePlaceholders.contains { $0.contains(expectedHTTPSOnlyMessage) })
        XCTAssertTrue(beforePlaceholders.contains { $0.contains(expectedNotAllowedMessage) })
        XCTAssertTrue(beforePlaceholders.contains { $0.contains("http://images.example.com/pixel.png") })
        let copiedHTTPImageURL = try await webView.evaluateJavaScript(
            """
            (function() {
              window.__copiedRemoteImageURLs = [];
              Object.defineProperty(navigator, 'clipboard', {
                configurable: true,
                value: {
                  writeText: function(value) {
                    window.__copiedRemoteImageURLs.push(String(value));
                    return Promise.resolve();
                  }
                }
              });
              var img = document.querySelector('img[alt="HTTP remote"]');
              var id = img && img.getAttribute('data-cmux-remote-placeholder-id');
              var placeholder = id && document.querySelector('[data-cmux-remote-placeholder-for="' + id + '"]');
              var button = placeholder && placeholder.querySelectorAll('button')[0];
              if (button) { button.click(); }
              return window.__copiedRemoteImageURLs;
            })();
            """
        )
        let copiedHTTPImageURLs = try XCTUnwrap(copiedHTTPImageURL as? [String])
        XCTAssertEqual(copiedHTTPImageURLs, ["http://images.example.com/pixel.png"])
        try await Task.sleep(nanoseconds: 100_000_000)
        let copiedHTTPButtonState = try await webView.evaluateJavaScript(
            """
            (function() {
              var img = document.querySelector('img[alt="HTTP remote"]');
              var id = img && img.getAttribute('data-cmux-remote-placeholder-id');
              var placeholder = id && document.querySelector('[data-cmux-remote-placeholder-for="' + id + '"]');
              var button = placeholder && placeholder.querySelectorAll('button')[0];
              return {
                text: button ? button.textContent : '',
                copied: button ? button.getAttribute('data-copied') : ''
              };
            })();
            """
        )
        let copiedHTTPButton = try XCTUnwrap(copiedHTTPButtonState as? [String: Any])
        XCTAssertEqual(copiedHTTPButton["text"] as? String, expectedCopiedButton)
        XCTAssertEqual(copiedHTTPButton["copied"] as? String, "1")
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let restoredHTTPButtonState = try await webView.evaluateJavaScript(
            """
            (function() {
              var img = document.querySelector('img[alt="HTTP remote"]');
              var id = img && img.getAttribute('data-cmux-remote-placeholder-id');
              var placeholder = id && document.querySelector('[data-cmux-remote-placeholder-for="' + id + '"]');
              var button = placeholder && placeholder.querySelectorAll('button')[0];
              return {
                text: button ? button.textContent : '',
                copied: button ? button.getAttribute('data-copied') : ''
              };
            })();
            """
        )
        let restoredHTTPButton = try XCTUnwrap(restoredHTTPButtonState as? [String: Any])
        XCTAssertEqual(restoredHTTPButton["text"] as? String, expectedCopyURLButton)
        XCTAssertNil(restoredHTTPButton["copied"] as? String)
        let openedHTTPImageURL = try await webView.evaluateJavaScript(
            """
            (function() {
              var opened = [];
              window.open = function(url, target, features) {
                opened.push({ url: String(url), target: String(target || ''), features: String(features || '') });
                return null;
              };
              var img = document.querySelector('img[alt="HTTP remote"]');
              var id = img && img.getAttribute('data-cmux-remote-placeholder-id');
              var placeholder = id && document.querySelector('[data-cmux-remote-placeholder-for="' + id + '"]');
              var button = placeholder && placeholder.querySelectorAll('button')[1];
              if (button) { button.click(); }
              return opened;
            })();
            """
        )
        let openedHTTPImageURLs = try XCTUnwrap(openedHTTPImageURL as? [[String: Any]])
        XCTAssertEqual(openedHTTPImageURLs.first?["url"] as? String, "http://images.example.com/pixel.png")
        XCTAssertEqual(openedHTTPImageURLs.first?["target"] as? String, "_blank")
        let linkedPlaceholderClickResult = try await webView.evaluateJavaScript(
            """
            (function() {
              var img = document.querySelector('img[alt="Linked remote"]');
              var id = img && img.getAttribute('data-cmux-remote-placeholder-id');
              var placeholder = id && document.querySelector('[data-cmux-remote-placeholder-for="' + id + '"]');
              var target = placeholder && (placeholder.querySelector('strong') || placeholder);
              if (!target) { return null; }
              return target.dispatchEvent(new MouseEvent('click', {
                bubbles: true,
                cancelable: true
              }));
            })();
            """
        )
        let linkedPlaceholderClickAllowed = try XCTUnwrap(linkedPlaceholderClickResult as? Bool)
        XCTAssertFalse(linkedPlaceholderClickAllowed)
        let linkedPlaceholderInsideAnchor = try await webView.evaluateJavaScript(
            """
            (function() {
              var img = document.querySelector('img[alt="Linked remote"]');
              var id = img && img.getAttribute('data-cmux-remote-placeholder-id');
              var placeholder = id && document.querySelector('[data-cmux-remote-placeholder-for="' + id + '"]');
              return !!(placeholder && placeholder.closest('a'));
            })();
            """
        )
        XCTAssertEqual(linkedPlaceholderInsideAnchor as? Bool, false)

        _ = try await webView.evaluateJavaScript(
            """
            (function() {
              var img = document.querySelector('img[alt="Linked remote"]');
              var id = img && img.getAttribute('data-cmux-remote-placeholder-id');
              var placeholder = id && document.querySelector('[data-cmux-remote-placeholder-for="' + id + '"]');
              var button = placeholder && placeholder.querySelector('button');
              if (button) { button.click(); }
            })();
            """
        )
        let loading = try await remoteImageSnapshot(in: webView)
        let loadingImages = try XCTUnwrap(loading["images"] as? [[String: Any]])
        let loadingPlaceholders = try XCTUnwrap(loading["placeholders"] as? [String])
        let loadingButtons = try XCTUnwrap(loading["buttons"] as? [String])
        let loadingButtonStates = try XCTUnwrap(loading["buttonStates"] as? [[String: Any]])
        let loadingHTTPSImage = try XCTUnwrap(loadingImages.first { $0["alt"] as? String == "HTTPS remote" })
        let loadingLinkedImage = try XCTUnwrap(loadingImages.first { $0["alt"] as? String == "Linked remote" })
        let loadingDuplicateImage = try XCTUnwrap(loadingImages.first { $0["alt"] as? String == "Duplicate linked remote" })
        let loadingExpandedIPv6Image = try XCTUnwrap(loadingImages.first { $0["alt"] as? String == "Expanded IPv6 mapped remote" })
        XCTAssertEqual(loadingHTTPSImage["src"] as? String, "")
        XCTAssertEqual(loadingHTTPSImage["hidden"] as? Bool, true)
        XCTAssertTrue((loadingLinkedImage["src"] as? String ?? "").hasPrefix("cmux-remote-image://"))
        XCTAssertEqual(loadingLinkedImage["hidden"] as? Bool, true)
        XCTAssertTrue((loadingDuplicateImage["src"] as? String ?? "").hasPrefix("cmux-remote-image://"))
        XCTAssertEqual(loadingDuplicateImage["hidden"] as? Bool, true)
        XCTAssertEqual(loadingExpandedIPv6Image["src"] as? String, "")
        XCTAssertEqual(loadingExpandedIPv6Image["hidden"] as? Bool, true)
        XCTAssertEqual(loadingPlaceholders.count, 7)
        XCTAssertEqual(loadingButtons.filter { $0 == expectedLoadButton }.count, 1)
        XCTAssertEqual(loadingButtons.filter { $0 == expectedLoadingButton }.count, 2)
        XCTAssertEqual(loadingButtons.filter { $0 == expectedCopyURLButton }.count, 7)
        XCTAssertEqual(loadingButtons.filter { $0 == expectedOpenURLButton }.count, 7)
        let activeLoadingButtons = loadingButtonStates.filter { $0["loading"] as? String == "1" }
        XCTAssertEqual(activeLoadingButtons.count, 2)
        XCTAssertTrue(activeLoadingButtons.allSatisfy { $0["text"] as? String == expectedLoadingButton })
        XCTAssertTrue(activeLoadingButtons.allSatisfy { $0["disabled"] as? Bool == true })

        _ = try await webView.evaluateJavaScript(
            """
            (function() {
              Array.prototype.slice.call(document.querySelectorAll('img[src^="cmux-remote-image://"]')).forEach(function(img) {
                img.dispatchEvent(new Event('load'));
              });
            })();
            """
        )
        let after = try await remoteImageSnapshot(in: webView)
        let afterImages = try XCTUnwrap(after["images"] as? [[String: Any]])
        let afterPlaceholders = try XCTUnwrap(after["placeholders"] as? [String])
        let afterButtons = try XCTUnwrap(after["buttons"] as? [String])
        let httpsImage = try XCTUnwrap(afterImages.first { $0["alt"] as? String == "HTTPS remote" })
        let linkedImage = try XCTUnwrap(afterImages.first { $0["alt"] as? String == "Linked remote" })
        let duplicateImage = try XCTUnwrap(afterImages.first { $0["alt"] as? String == "Duplicate linked remote" })
        let httpImage = try XCTUnwrap(afterImages.first { $0["alt"] as? String == "HTTP remote" })
        let localhostImage = try XCTUnwrap(afterImages.first { $0["alt"] as? String == "Localhost remote" })
        let credentialImage = try XCTUnwrap(afterImages.first { $0["alt"] as? String == "Credential remote" })
        let expandedIPv6Image = try XCTUnwrap(afterImages.first { $0["alt"] as? String == "Expanded IPv6 mapped remote" })

        XCTAssertEqual(httpsImage["src"] as? String, "")
        XCTAssertEqual(httpsImage["hidden"] as? Bool, true)
        XCTAssertTrue((linkedImage["src"] as? String ?? "").hasPrefix("cmux-remote-image://"))
        XCTAssertEqual(linkedImage["hidden"] as? Bool, false)
        XCTAssertTrue((duplicateImage["src"] as? String ?? "").hasPrefix("cmux-remote-image://"))
        XCTAssertEqual(duplicateImage["hidden"] as? Bool, false)
        XCTAssertEqual(httpImage["src"] as? String, "")
        XCTAssertEqual(httpImage["hidden"] as? Bool, true)
        XCTAssertEqual(localhostImage["src"] as? String, "")
        XCTAssertEqual(localhostImage["hidden"] as? Bool, true)
        XCTAssertEqual(credentialImage["src"] as? String, "")
        XCTAssertEqual(credentialImage["hidden"] as? Bool, true)
        XCTAssertEqual(expandedIPv6Image["src"] as? String, "")
        XCTAssertEqual(expandedIPv6Image["hidden"] as? Bool, true)
        XCTAssertEqual(afterPlaceholders.count, 5)
        XCTAssertEqual(afterButtons.filter { $0 == expectedLoadButton }.count, 1)
        XCTAssertEqual(afterButtons.filter { $0 == expectedCopyURLButton }.count, 5)
        XCTAssertEqual(afterButtons.filter { $0 == expectedOpenURLButton }.count, 5)
        XCTAssertTrue(afterPlaceholders.contains { $0.contains(expectedHTTPSOnlyMessage) })
        XCTAssertTrue(afterPlaceholders.contains { $0.contains(expectedNotAllowedMessage) })

        try await renderMarkdown(
            "![Different same-host remote](https://images.example.com/auto.png)\n",
            in: webView
        )
        let differentSameHost = try await remoteImageSnapshot(in: webView)
        let differentSameHostImages = try XCTUnwrap(differentSameHost["images"] as? [[String: Any]])
        let differentSameHostPlaceholders = try XCTUnwrap(differentSameHost["placeholders"] as? [String])
        let differentSameHostButtons = try XCTUnwrap(differentSameHost["buttons"] as? [String])
        let differentSameHostImage = try XCTUnwrap(differentSameHostImages.first)
        XCTAssertEqual(differentSameHostImage["src"] as? String, "")
        XCTAssertEqual(differentSameHostImage["hidden"] as? Bool, true)
        XCTAssertEqual(differentSameHostPlaceholders.count, 1)
        XCTAssertEqual(differentSameHostButtons.filter { $0 == expectedLoadButton }.count, 1)
        XCTAssertEqual(differentSameHostButtons.filter { $0 == expectedCopyURLButton }.count, 1)
        XCTAssertEqual(differentSameHostButtons.filter { $0 == expectedOpenURLButton }.count, 1)

        try await renderMarkdown(
            "![Auto approved remote](https://images.example.com/linked.png)\n",
            in: webView
        )
        let autoLoading = try await remoteImageSnapshot(in: webView)
        let autoLoadingImages = try XCTUnwrap(autoLoading["images"] as? [[String: Any]])
        let autoLoadingPlaceholders = try XCTUnwrap(autoLoading["placeholders"] as? [String])
        let autoLoadingButtons = try XCTUnwrap(autoLoading["buttons"] as? [String])
        let autoLoadingButtonStates = try XCTUnwrap(autoLoading["buttonStates"] as? [[String: Any]])
        let autoLoadingImage = try XCTUnwrap(autoLoadingImages.first)
        XCTAssertTrue((autoLoadingImage["src"] as? String ?? "").hasPrefix("cmux-remote-image://"))
        XCTAssertEqual(autoLoadingImage["hidden"] as? Bool, true)
        XCTAssertEqual(autoLoadingPlaceholders.count, 1)
        XCTAssertEqual(autoLoadingButtons.filter { $0 == expectedLoadButton }.count, 0)
        XCTAssertEqual(autoLoadingButtons.filter { $0 == expectedLoadingButton }.count, 1)
        XCTAssertEqual(autoLoadingButtons.filter { $0 == expectedCopyURLButton }.count, 1)
        XCTAssertEqual(autoLoadingButtons.filter { $0 == expectedOpenURLButton }.count, 1)
        XCTAssertEqual(autoLoadingButtonStates.filter { $0["loading"] as? String == "1" }.count, 1)

        _ = try await webView.evaluateJavaScript(
            """
            (function() {
              var img = document.querySelector('img[alt="Auto approved remote"]');
              if (img) { img.dispatchEvent(new Event('error')); }
            })();
            """
        )
        let autoFailed = try await remoteImageSnapshot(in: webView)
        let autoFailedImages = try XCTUnwrap(autoFailed["images"] as? [[String: Any]])
        let autoFailedPlaceholders = try XCTUnwrap(autoFailed["placeholders"] as? [String])
        let autoFailedButtons = try XCTUnwrap(autoFailed["buttons"] as? [String])
        let autoFailedImage = try XCTUnwrap(autoFailedImages.first)
        XCTAssertEqual(autoFailedImage["src"] as? String, "")
        XCTAssertEqual(autoFailedImage["hidden"] as? Bool, true)
        XCTAssertEqual(autoFailedPlaceholders.count, 1)
        XCTAssertEqual(autoFailedButtons.filter { $0 == expectedLoadButton }.count, 1)
        XCTAssertEqual(autoFailedButtons.filter { $0 == expectedLoadingButton }.count, 0)
        XCTAssertEqual(autoFailedButtons.filter { $0 == expectedCopyURLButton }.count, 1)
        XCTAssertEqual(autoFailedButtons.filter { $0 == expectedOpenURLButton }.count, 1)
    }

    func testMarkdownRemoteImageSecurityRejectsUnsafeTargets() throws {
        func url(_ string: String) throws -> URL {
            try XCTUnwrap(URL(string: string))
        }

        XCTAssertTrue(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://example.com/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("http://example.com/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://user:pass@example.com/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://example.com:8443/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://localhost/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://127.0.0.1/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://10.0.0.2/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://172.16.0.1/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://192.168.1.1/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://169.254.169.254/latest/meta-data")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://[::1]/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://[fe80::1]/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://[fec0::1]/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://[fc00::1]/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://[::127.0.0.1]/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isSafeRemoteImageURL(
                try url("https://2130706433/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isSafeRemoteImageURL(
                try url("https://0x7f000001/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isSafeRemoteImageURL(
                try url("https://127.1/image.png")
            )
        )
        XCTAssertFalse(
            MarkdownRemoteImageSecurity.isSafeRemoteImageURL(
                try url("https://10.1/image.png")
            )
        )
        let pinnedTargets = MarkdownRemoteImageSecurity.pinnedFetchTargets(
            for: try url("https://1.1.1.1/image.png")
        )
        XCTAssertEqual(pinnedTargets.count, 1)
        XCTAssertEqual(pinnedTargets.first?.serverName, "1.1.1.1")
        let approvedHost = try XCTUnwrap(
            MarkdownRemoteImageSecurity.remoteImageConsentHost(
                for: try url("https://images.example.com/pixel.png")
            )
        )
        XCTAssertEqual(
            MarkdownRemoteImageSecurity.remoteImageConsentHost(
                for: try url("https://images.example.com/redirected.png")
            ),
            approvedHost
        )
        XCTAssertNotEqual(
            MarkdownRemoteImageSecurity.remoteImageConsentHost(
                for: try url("https://cdn.example.com/redirected.png")
            ),
            approvedHost
        )
        XCTAssertEqual(MarkdownRemoteImageSecurity.canonicalImageMIMEType("image/png"), "image/png")
        XCTAssertEqual(MarkdownRemoteImageSecurity.canonicalImageMIMEType("image/svg+xml"), "image/svg+xml")
        XCTAssertEqual(
            MarkdownRemoteImageSecurity.canonicalImageMIMEType("image/svg+xml;charset=utf-8"),
            "image/svg+xml"
        )
        let ipv6RequestBytes = try XCTUnwrap(
            MarkdownRemoteImageSecurity.requestBytes(
                for: try url("https://[2606:4700:4700::1111]/image.png"),
                host: "2606:4700:4700::1111"
            )
        )
        let ipv6Request = try XCTUnwrap(String(data: ipv6RequestBytes, encoding: .utf8))
        let acceptLine = try XCTUnwrap(
            ipv6Request.components(separatedBy: "\r\n").first { $0.hasPrefix("Accept: ") }
        )
        XCTAssertEqual(
            acceptLine,
            "Accept: image/png,image/jpeg,image/gif,image/webp,image/avif;q=0.9,image/svg+xml;q=0.9,*/*;q=0.1"
        )
        XCTAssertTrue(ipv6Request.contains("\r\nHost: [2606:4700:4700::1111]\r\n"))
    }

    func testMarkdownRemoteImageChunkedDecoderRejectsOversizedChunks() {
        XCTAssertEqual(
            MarkdownHTTPChunkedBodyDecoder.decode(
                Data("3\r\nabc\r\n0\r\n\r\n".utf8),
                maximumBytes: 8
            ),
            Data("abc".utf8)
        )
        XCTAssertNil(
            MarkdownHTTPChunkedBodyDecoder.decode(
                Data("9\r\nabcdefghi\r\n0\r\n\r\n".utf8),
                maximumBytes: 8
            )
        )
        XCTAssertNil(
            MarkdownHTTPChunkedBodyDecoder.decode(
                Data("7fffffffffffffff\r\n".utf8),
                maximumBytes: 8
            )
        )
    }

    private func remoteImageSnapshot(in webView: WKWebView) async throws -> [String: Any] {
        let result = try await webView.evaluateJavaScript(
            """
            (function() {
              return {
                images: Array.prototype.slice.call(document.querySelectorAll('img')).map(function(img) {
                  return {
                    alt: img.getAttribute('alt') || '',
                    src: img.getAttribute('src') || '',
                    currentSrc: img.currentSrc || '',
                    hidden: !!img.hidden,
                    remoteSrc: img.getAttribute('data-cmux-remote-src') || ''
                  };
                }),
                placeholders: Array.prototype.slice.call(document.querySelectorAll('.cmux-remote-image-placeholder')).map(function(el) {
                  return el.textContent || '';
                }),
                remoteImageURLs: Array.prototype.slice.call(document.querySelectorAll('.cmux-remote-image-url')).map(function(el) {
                  return el.textContent || '';
                }),
                buttons: Array.prototype.slice.call(document.querySelectorAll('.cmux-remote-image-placeholder button')).map(function(el) {
                  return el.textContent || '';
                }),
                buttonStates: Array.prototype.slice.call(document.querySelectorAll('.cmux-remote-image-placeholder button')).map(function(el) {
                  return {
                    text: el.textContent || '',
                    loading: el.getAttribute('data-loading') || '',
                    disabled: !!el.disabled
                  };
                }),
                codeFiles: Array.prototype.slice.call(document.querySelectorAll('code[data-cmux-file]')).map(function(el) {
                  return decodeURIComponent(el.getAttribute('data-cmux-file') || '');
                }),
                styleCount: document.getElementById('content').querySelectorAll('style').length,
                backgroundAttrCount: document.getElementById('content').querySelectorAll('[background]').length,
                renderedText: window.__cmuxRenderedText ? window.__cmuxRenderedText() : ''
              };
            })();
            """
        )
        return try XCTUnwrap(result as? [String: Any])
    }

}
