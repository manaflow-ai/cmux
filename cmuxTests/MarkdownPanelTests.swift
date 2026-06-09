import AppKit
import Combine
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MarkdownPanelTests: XCTestCase {
    private var originalRuntimeSurfaceCreationSuppression = false

    override func setUp() {
        super.setUp()
        originalRuntimeSurfaceCreationSuppression = TerminalSurface.debugSuppressRuntimeSurfaceCreationForTesting
        TerminalSurface.debugSuppressRuntimeSurfaceCreationForTesting = true
    }

    override func tearDown() {
        TerminalSurface.debugSuppressRuntimeSurfaceCreationForTesting = originalRuntimeSurfaceCreationSuppression
        TerminalController.shared.setActiveTabManager(nil)
        super.tearDown()
    }

    func testMarkdownThemeUsesTransparentPageAndOverlayTintsForTranslucentBackgrounds() throws {
        let theme = MarkdownWebTheme.resolve(
            backgroundColor: NSColor(
                srgbRed: 0.10,
                green: 0.12,
                blue: 0.14,
                alpha: 0.42
            )
        )

        XCTAssertTrue(theme.isDark)
        XCTAssertEqual(theme.background, "transparent")
        XCTAssertEqual(Self.cssRGBAComponents(theme.mutedBackground)?.red, 255)
        XCTAssertEqual(Self.cssRGBAComponents(theme.mutedBackground)?.green, 255)
        XCTAssertEqual(Self.cssRGBAComponents(theme.mutedBackground)?.blue, 255)
        XCTAssertEqual(Self.cssRGBAComponents(theme.neutralMutedBackground)?.red, 255)
        XCTAssertGreaterThan(
            try XCTUnwrap(Self.cssRGBAComponents(theme.neutralMutedBackground)?.alpha),
            try XCTUnwrap(Self.cssRGBAComponents(theme.mutedBackground)?.alpha)
        )
        XCTAssertFalse(theme.mutedBackground.contains("0.420"))
        XCTAssertFalse(theme.neutralMutedBackground.contains("0.420"))
    }

    func testMarkdownThemeOverlayFallsBackToFullOverlayWhenContrastIsUnreachable() {
        let base = NSColor(srgbRed: 0.2, green: 0.24, blue: 0.28, alpha: 0.4)
        let overlay = base.markdownThemeOverlay(targetContrast: 21, of: base)

        XCTAssertEqual(overlay.alphaComponent, 1, accuracy: 0.0001)
    }

    func testMarkdownFontSizeSettingsClampAndPageZoom() {
        XCTAssertEqual(MarkdownFontSizeSettings.clamp(5), MarkdownFontSizeSettings.minimumPointSize)
        XCTAssertEqual(MarkdownFontSizeSettings.clamp(1000), MarkdownFontSizeSettings.maximumPointSize)
        XCTAssertEqual(MarkdownFontSizeSettings.clamp(20), 20)

        // pageZoom = pointSize / baseRenderPointSize (15px body).
        XCTAssertEqual(MarkdownFontSizeSettings.pageZoom(forPointSize: 15), 1.0, accuracy: 0.0001)
        XCTAssertEqual(MarkdownFontSizeSettings.pageZoom(forPointSize: 30), 2.0, accuracy: 0.0001)
        // Out-of-range sizes clamp before converting to a zoom factor.
        XCTAssertEqual(
            MarkdownFontSizeSettings.pageZoom(forPointSize: 4),
            CGFloat(MarkdownFontSizeSettings.minimumPointSize / MarkdownFontSizeSettings.baseRenderPointSize),
            accuracy: 0.0001
        )
    }

    func testMarkdownFontSizeSettingsResolvedDefaultHonorsDefaults() throws {
        let suiteName = "cmux.markdownFontSizeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Unset -> baseline default.
        XCTAssertEqual(MarkdownFontSizeSettings.resolvedDefault(defaults: defaults), MarkdownFontSizeSettings.defaultPointSize)

        // In-range override is honored.
        defaults.set(22, forKey: MarkdownFontSizeSettings.key)
        XCTAssertEqual(MarkdownFontSizeSettings.resolvedDefault(defaults: defaults), 22)

        // Out-of-range override is clamped.
        defaults.set(500, forKey: MarkdownFontSizeSettings.key)
        XCTAssertEqual(MarkdownFontSizeSettings.resolvedDefault(defaults: defaults), MarkdownFontSizeSettings.maximumPointSize)
    }

    func testMarkdownFontFamilyNormalizesDefaultsAndEscapesCSSValue() throws {
        let suiteName = "cmux.markdownFontFamilyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(MarkdownFontFamily.resolvedDefault(defaults: defaults), MarkdownFontFamily.systemDefault)
        XCTAssertNil(MarkdownFontFamily.cssValue(for: ""))

        MarkdownFontFamily.setDefault("  Avenir Next  \n", defaults: defaults)
        XCTAssertEqual(MarkdownFontFamily.resolvedDefault(defaults: defaults), "Avenir Next")
        XCTAssertEqual(MarkdownFontFamily.cssValue(for: #"Quote " Test \ Family"#), #""Quote \" Test \\ Family""#)

        MarkdownFontFamily.setDefault(" \n ", defaults: defaults)
        XCTAssertNil(defaults.object(forKey: MarkdownFontFamily.key))
    }

    func testMarkdownMaxWidthSettingsClampAndResolvedDefault() throws {
        XCTAssertEqual(MarkdownMaxWidthSettings.clamp(200), MarkdownMaxWidthSettings.minimumCSSPixels)
        XCTAssertEqual(MarkdownMaxWidthSettings.clamp(4000), MarkdownMaxWidthSettings.maximumCSSPixels)
        XCTAssertEqual(MarkdownMaxWidthSettings.clamp(980), 980)

        let suiteName = "cmux.markdownMaxWidthTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(MarkdownMaxWidthSettings.resolvedDefault(defaults: defaults), MarkdownMaxWidthSettings.defaultCSSPixels)

        MarkdownMaxWidthSettings.setDefault(1220, defaults: defaults)
        XCTAssertEqual(MarkdownMaxWidthSettings.resolvedDefault(defaults: defaults), 1220)

        defaults.set(10000, forKey: MarkdownMaxWidthSettings.key)
        XCTAssertEqual(MarkdownMaxWidthSettings.resolvedDefault(defaults: defaults), MarkdownMaxWidthSettings.maximumCSSPixels)

        MarkdownMaxWidthSettings.resetDefault(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: MarkdownMaxWidthSettings.key))
    }

    func testMarkdownPanelZoomStepsClampAndReset() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-zoom-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("README.md")
        try "# hello".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: directoryURL) }

        // Pin the persisted default to a non-boundary value so the reset
        // assertions below don't depend on (or mutate) the developer's settings.
        let defaultsKey = MarkdownFontSizeSettings.key
        let savedDefault = UserDefaults.standard.object(forKey: defaultsKey)
        UserDefaults.standard.set(20, forKey: defaultsKey)
        defer {
            if let savedDefault {
                UserDefaults.standard.set(savedDefault, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: fileURL.path, fontSize: 15)
        defer { panel.close() }

        XCTAssertEqual(panel.fontSize, 15)

        // Each step changes by exactly one point and reports the change.
        XCTAssertTrue(panel.zoomOut())
        XCTAssertEqual(panel.fontSize, 15 - MarkdownFontSizeSettings.stepPointSize)
        XCTAssertTrue(panel.zoomIn())
        XCTAssertEqual(panel.fontSize, 15)

        // Zooming out clamps at the minimum and then reports no change.
        var guardCount = 0
        while panel.zoomOut() { guardCount += 1; XCTAssertLessThan(guardCount, 1000) }
        XCTAssertEqual(panel.fontSize, MarkdownFontSizeSettings.minimumPointSize)
        XCTAssertFalse(panel.zoomOut())

        // Reset returns to the configured default (seeded to 20 above) and
        // reports the change.
        XCTAssertTrue(panel.resetZoom())
        XCTAssertEqual(panel.fontSize, 20)
        XCTAssertFalse(panel.resetZoom())
    }

    func testMarkdownPanelTypographyResetsToConfiguredDefaults() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-typography-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("README.md")
        try "# hello".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let savedSize = UserDefaults.standard.object(forKey: MarkdownFontSizeSettings.key)
        let savedFamily = UserDefaults.standard.object(forKey: MarkdownFontFamily.key)
        UserDefaults.standard.set(19, forKey: MarkdownFontSizeSettings.key)
        UserDefaults.standard.set("Avenir Next", forKey: MarkdownFontFamily.key)
        defer {
            if let savedSize {
                UserDefaults.standard.set(savedSize, forKey: MarkdownFontSizeSettings.key)
            } else {
                UserDefaults.standard.removeObject(forKey: MarkdownFontSizeSettings.key)
            }
            if let savedFamily {
                UserDefaults.standard.set(savedFamily, forKey: MarkdownFontFamily.key)
            } else {
                UserDefaults.standard.removeObject(forKey: MarkdownFontFamily.key)
            }
        }

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: fileURL.path, fontSize: 15)
        defer { panel.close() }

        XCTAssertEqual(panel.fontFamily, "Avenir Next")
        XCTAssertTrue(panel.setFontFamily("  Menlo  \n"))
        XCTAssertEqual(panel.fontFamily, "Menlo")
        panel.resetTypography()
        XCTAssertEqual(panel.fontSize, 19)
        XCTAssertEqual(panel.fontFamily, "Avenir Next")
    }

    func testFileOpenRoutesMarkdownFilesToPreviewMarkdownPanel() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-file-open-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            try? fileManager.removeItem(at: directoryURL)
        }

        let fileURL = directoryURL.appendingPathComponent("README.md")
        try "# Title\n\nBody.\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        TerminalController.shared.setActiveTabManager(manager)

        let result = TerminalController.shared.v2FileOpen(params: [
            "paths": [fileURL.path],
            "workspace_id": workspace.id.uuidString,
            "pane_id": pane.id.uuidString,
            "focus": false
        ])

        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let openedPanelIdString = payload["surface_id"] as? String,
              let openedPanelId = UUID(uuidString: openedPanelIdString) else {
            XCTFail("Expected file.open to succeed for markdown, got \(result)")
            return
        }

        let panel = try XCTUnwrap(workspace.markdownPanel(for: openedPanelId))
        XCTAssertEqual(panel.filePath, fileURL.path)
        XCTAssertEqual(panel.displayMode, .preview)
        XCTAssertNil(workspace.filePreviewPanel(for: openedPanelId))
        XCTAssertEqual(payload["panel_type"] as? String, PanelType.markdown.rawValue)
        XCTAssertEqual(payload["display_mode"] as? String, MarkdownPanelDisplayMode.preview.rawValue)
    }

    func testExternalFileOpenRoutesMarkdownFilesToPreviewMarkdownPanel() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-external-open-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directoryURL)
        }

        let fileURL = directoryURL.appendingPathComponent("README.md")
        try "# Title\n\nBody.\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer {
            AppDelegate.shared = previousShared
        }

        let manager = TabManager()
        let workspace = manager.addWorkspace(
            workingDirectory: directoryURL.path,
            select: true,
            eagerLoadTerminal: false
        )
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            for panel in workspace.panels.values {
                panel.close()
            }
        }
        TerminalController.shared.setActiveTabManager(manager)

#if DEBUG
        appDelegate.registerMainWindowContextForTesting(tabManager: manager)
#else
        XCTFail("registerMainWindowContextForTesting is only available in DEBUG")
        return
#endif

        XCTAssertTrue(
            appDelegate.openFilePreviewInPreferredMainWindow(
                filePath: fileURL.path,
                debugSource: "unit-test"
            )
        )

        let markdownPanels = workspace.panels.values.compactMap { $0 as? MarkdownPanel }
        XCTAssertEqual(markdownPanels.count, 1)
        let originalMarkdownPanel = try XCTUnwrap(markdownPanels.first)
        let originalMarkdownPanelID = ObjectIdentifier(originalMarkdownPanel)
        XCTAssertEqual(originalMarkdownPanel.filePath, fileURL.path)
        XCTAssertEqual(originalMarkdownPanel.displayMode, .preview)
        XCTAssertTrue(workspace.panels.values.compactMap { $0 as? FilePreviewPanel }.isEmpty)

        XCTAssertTrue(
            appDelegate.openFilePreviewInPreferredMainWindow(
                filePath: fileURL.path,
                debugSource: "unit-test-reopen"
            )
        )
        let reopenedMarkdownPanels = workspace.panels.values.compactMap { $0 as? MarkdownPanel }
        XCTAssertEqual(reopenedMarkdownPanels.count, 1)
        XCTAssertTrue(reopenedMarkdownPanels.contains { ObjectIdentifier($0) == originalMarkdownPanelID })
    }

    func testOpenMarkdownPanelReloadsWhenFileChangesOnDisk() async throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-panel-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appendingPathComponent("live.md")
        let originalContent = "# Original\n\nBody before save.\n"
        let updatedContent = "# Updated\n\nBody after external save.\n"
        try originalContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }

        XCTAssertEqual(panel.content, originalContent)
        XCTAssertFalse(panel.isFileUnavailable)

        let reloaded = expectation(description: "markdown file change reloaded")
        var didFulfillReload = false
        let cancellable = panel.$content.dropFirst().sink { content in
            if content == updatedContent, !didFulfillReload {
                didFulfillReload = true
                reloaded.fulfill()
            }
        }
        defer { cancellable.cancel() }

        try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [reloaded], timeout: 3)
        XCTAssertEqual(panel.content, updatedContent)
        XCTAssertEqual(panel.textContent, updatedContent)
        XCTAssertFalse(panel.isDirty)
    }

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

        let coordinator = MarkdownWebRenderer.Coordinator()
        coordinator.filePath = markdownURL.path
        defer { coordinator.cancelLocalImageLoads() }

        func localImageRequestURL(_ fileURL: URL) throws -> URL {
            var components = URLComponents()
            components.scheme = MarkdownWebRenderer.localImageURLScheme
            components.host = "image"
            components.queryItems = [URLQueryItem(name: "url", value: fileURL.absoluteString)]
            return try XCTUnwrap(components.url)
        }

        let localFinished = expectation(description: "local image request finished")
        let localTask = MarkdownURLSchemeTaskSpy(
            request: URLRequest(url: try localImageRequestURL(imageURL)),
            finishedExpectation: localFinished
        )
        coordinator.webView(WKWebView(frame: .zero), start: localTask)

        let outsideFinished = expectation(description: "outside image request finished")
        let outsideTask = MarkdownURLSchemeTaskSpy(
            request: URLRequest(url: try localImageRequestURL(outsideImageURL)),
            finishedExpectation: outsideFinished
        )
        coordinator.webView(WKWebView(frame: .zero), start: outsideTask)

        await fulfillment(of: [localFinished, outsideFinished], timeout: 2)

        let localSnapshot = localTask.snapshot()
        XCTAssertEqual(localSnapshot.responses.count, 1)
        XCTAssertEqual(localSnapshot.responses.first?.mimeType, "image/png")
        XCTAssertEqual(localSnapshot.data, Self.onePixelPNG)
        XCTAssertTrue(localSnapshot.didFinish)
        XCTAssertNil(localSnapshot.error)

        let outsideSnapshot = outsideTask.snapshot()
        XCTAssertEqual(outsideSnapshot.responses.count, 1)
        XCTAssertEqual(outsideSnapshot.responses.first?.mimeType, "image/png")
        XCTAssertEqual(outsideSnapshot.data, Data())
        XCTAssertTrue(outsideSnapshot.didFinish)
        XCTAssertNil(outsideSnapshot.error)
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

    func testMarkdownRenderBlocksRemoteImagesUntilUserAction() throws {
        func url(_ string: String) throws -> URL {
            try XCTUnwrap(URL(string: string))
        }

        let loadableImage = try url("https://images.example.com/pixel.png")
        let linkedImage = try url("https://images.example.com/linked.png")
        let unsafeHTTPImage = try url("http://images.example.com/pixel.png")
        let unsafeLocalImage = try url("https://localhost/pixel.png")
        let unsafeCredentialedImage = try url("https://user:pass@images.example.com/secret.png")

        XCTAssertTrue(MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(loadableImage))
        XCTAssertEqual(
            MarkdownRemoteImageSecurity.remoteImageConsentHost(for: loadableImage),
            "images.example.com"
        )
        XCTAssertEqual(
            MarkdownRemoteImageSecurity.remoteImageConsentHost(for: linkedImage),
            "images.example.com"
        )
        XCTAssertNil(MarkdownRemoteImageSecurity.remoteImageConsentHost(for: unsafeHTTPImage))
        XCTAssertNil(MarkdownRemoteImageSecurity.remoteImageConsentHost(for: unsafeLocalImage))
        XCTAssertNil(MarkdownRemoteImageSecurity.remoteImageConsentHost(for: unsafeCredentialedImage))

        let requestBytes = try XCTUnwrap(
            MarkdownRemoteImageSecurity.requestBytes(for: loadableImage, host: "images.example.com")
        )
        let request = try XCTUnwrap(String(data: requestBytes, encoding: .utf8))
        XCTAssertTrue(request.contains("GET /pixel.png HTTP/1.1\r\n"))
        XCTAssertTrue(request.contains("\r\nHost: images.example.com\r\n"))
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
            MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(
                try url("https://[0:0:0:0:0:ffff:7f00:1]/image.png")
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

    private static func cssRGBAComponents(_ css: String) -> (red: Int, green: Int, blue: Int, alpha: Double)? {
        let pattern = #"rgba\((\d+), (\d+), (\d+), ([0-9.]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: css, range: NSRange(css.startIndex..., in: css)),
              match.numberOfRanges == 5 else {
            return nil
        }
        func string(at index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: css) else { return nil }
            return String(css[range])
        }
        guard let red = string(at: 1).flatMap(Int.init),
              let green = string(at: 2).flatMap(Int.init),
              let blue = string(at: 3).flatMap(Int.init),
              let alpha = string(at: 4).flatMap(Double.init) else {
            return nil
        }
        return (red, green, blue, alpha)
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

}

private final class MarkdownURLSchemeTaskSpy: NSObject, WKURLSchemeTask {
    struct Snapshot {
        let responses: [URLResponse]
        let data: Data
        let didFinish: Bool
        let error: Error?
    }

    let request: URLRequest
    private let finishedExpectation: XCTestExpectation
    private let lock = NSLock()
    private var responses: [URLResponse] = []
    private var receivedData = Data()
    private var finished = false
    private var receivedError: Error?

    init(request: URLRequest, finishedExpectation: XCTestExpectation) {
        self.request = request
        self.finishedExpectation = finishedExpectation
    }

    func didReceive(_ response: URLResponse) {
        lock.lock()
        responses.append(response)
        lock.unlock()
    }

    func didReceive(_ data: Data) {
        lock.lock()
        receivedData.append(data)
        lock.unlock()
    }

    func didFinish() {
        lock.lock()
        let shouldFulfill = !finished
        finished = true
        lock.unlock()
        if shouldFulfill {
            finishedExpectation.fulfill()
        }
    }

    func didFailWithError(_ error: Error) {
        lock.lock()
        let shouldFulfill = !finished && receivedError == nil
        receivedError = error
        lock.unlock()
        if shouldFulfill {
            finishedExpectation.fulfill()
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            responses: responses,
            data: receivedData,
            didFinish: finished,
            error: receivedError
        )
    }
}
