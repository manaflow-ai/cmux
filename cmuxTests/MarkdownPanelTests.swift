import AppKit
import Carbon.HIToolbox
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

        workspace.focusPanel(panel.id)
        try assertStartSearchRoutesToFocusedMarkdownPreviewPanel(
            manager: manager,
            workspace: workspace,
            panel: panel,
            filePath: fileURL.path
        )
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

    private func assertStartSearchRoutesToFocusedMarkdownPreviewPanel(
        manager: TabManager,
        workspace: Workspace,
        panel: MarkdownPanel,
        filePath: String
    ) throws {
        let webView = MarkdownWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: WKWebViewConfiguration())
        var capturedEvents: [NSEvent] = []
        webView.performKeyEquivalentHandler = { event in
            capturedEvents.append(event)
            return true
        }
        panel.rendererSession
            .coordinator(panelId: panel.id, workspaceId: workspace.id, filePath: filePath)
            .webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentView?.bounds ?? webView.bounds)
        contentView.addSubview(webView)
        window.contentView = contentView
        window.makeFirstResponder(webView)
        defer { window.close() }

        XCTAssertEqual(workspace.focusedPanelId, panel.id)
        XCTAssertEqual(panel.displayMode, .preview)
        XCTAssertFalse(manager.isFindVisible)
        XCTAssertTrue(
            manager.startSearch(),
            "Cmd+F should be handled by the focused Markdown preview panel instead of being dropped."
        )
        XCTAssertFalse(
            manager.isFindVisible,
            "The test double handles Cmd+F but does not create WebKit's native find UI."
        )
        let event = try XCTUnwrap(capturedEvents.last)
        XCTAssertEqual(event.charactersIgnoringModifiers, "f")
        XCTAssertEqual(event.keyCode, UInt16(kVK_ANSI_F))
        XCTAssertTrue(event.modifierFlags.contains(.command))
        XCTAssertFalse(event.modifierFlags.contains(.shift))

        XCTAssertTrue(manager.canUseSelectionForFind)
        manager.searchSelection()
        let useSelectionEvent = try XCTUnwrap(capturedEvents.last)
        XCTAssertEqual(useSelectionEvent.charactersIgnoringModifiers, "e")
        XCTAssertEqual(useSelectionEvent.keyCode, UInt16(kVK_ANSI_E))
        XCTAssertTrue(useSelectionEvent.modifierFlags.contains(.command))

        manager.findNext()
        let nextEvent = try XCTUnwrap(capturedEvents.last)
        XCTAssertEqual(nextEvent.charactersIgnoringModifiers, "g")
        XCTAssertEqual(nextEvent.keyCode, UInt16(kVK_ANSI_G))
        XCTAssertTrue(nextEvent.modifierFlags.contains(.command))
        XCTAssertFalse(nextEvent.modifierFlags.contains(.shift))

        manager.findPrevious()
        let previousEvent = try XCTUnwrap(capturedEvents.last)
        XCTAssertEqual(previousEvent.charactersIgnoringModifiers, "g")
        XCTAssertEqual(previousEvent.keyCode, UInt16(kVK_ANSI_G))
        XCTAssertTrue(previousEvent.modifierFlags.contains(.command))
        XCTAssertTrue(previousEvent.modifierFlags.contains(.shift))
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
        let cancellable = panel.$content.dropFirst().sink { content in
            if content == updatedContent {
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

    func testMarkdownRendererReentersWindowReloadsShellAfterRecoveryBudgetExhausted() {
        let coordinator = MarkdownWebRenderer.Coordinator()
        let webView = MarkdownWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let theme = MarkdownWebTheme.resolve(backgroundColor: .windowBackgroundColor)
        coordinator.webView = webView
        defer { coordinator.close() }

        // Document was healthy when the pane was dragged out of its column.
        coordinator.loadShell(theme: theme, initialMarkdown: "# Existing\n")
        coordinator.webView(webView, didFinish: nil)
        coordinator.handleViewLeftWindow()

        // While detached, WebKit reclaimed the WebContent process and the
        // in-place recovery budget was exhausted, leaving the panel blank.
        for _ in 0...2 {
            coordinator.webViewWebContentProcessDidTerminate(webView)
        }
        XCTAssertEqual(coordinator.webContentProcessRecoveryAttemptsForTesting, 2)
        XCTAssertFalse(coordinator.isShellLoadingForTesting)

        // Re-parenting the pane back into a window must recover the blank
        // panel: reset the recovery budget and reload the shell.
        coordinator.handleViewReenteredWindow()

        XCTAssertEqual(coordinator.webContentProcessRecoveryAttemptsForTesting, 0)
        XCTAssertTrue(coordinator.isShellLoadingForTesting)
    }

    func testMarkdownRendererReentersWindowKeepsLoadedShell() {
        let coordinator = MarkdownWebRenderer.Coordinator()
        let webView = MarkdownWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let theme = MarkdownWebTheme.resolve(backgroundColor: .windowBackgroundColor)
        coordinator.webView = webView
        defer { coordinator.close() }

        // A still-loaded shell (WebContent process alive, just unpainted) must
        // not be torn down and reloaded when the view re-enters a window.
        coordinator.loadShell(theme: theme, initialMarkdown: "# Existing\n")
        // Consume part of the per-payload crash-recovery budget, then finish a
        // successful reload so the shell is loaded again.
        coordinator.webViewWebContentProcessDidTerminate(webView)
        coordinator.webView(webView, didFinish: nil)
        XCTAssertEqual(coordinator.webContentProcessRecoveryAttemptsForTesting, 1)
        XCTAssertFalse(coordinator.isShellLoadingForTesting)

        coordinator.handleViewLeftWindow()
        coordinator.handleViewReenteredWindow()

        // Re-entry on a loaded shell must not reload it, and must preserve the
        // per-payload crash budget so reparent/layout churn can't grant a
        // crashing payload extra recovery cycles.
        XCTAssertFalse(coordinator.isShellLoadingForTesting)
        XCTAssertEqual(coordinator.webContentProcessRecoveryAttemptsForTesting, 1)
    }

    func testMarkdownRendererReentersWindowDoesNotReviveCrashLoopingPayload() {
        let coordinator = MarkdownWebRenderer.Coordinator()
        let webView = MarkdownWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let theme = MarkdownWebTheme.resolve(backgroundColor: .windowBackgroundColor)
        coordinator.webView = webView
        defer { coordinator.close() }

        // A payload that keeps crashing WebContent *while attached* exhausts
        // the recovery budget and is intentionally left blank by the crash-loop
        // guard — the shell was never healthy when detached.
        coordinator.loadShell(theme: theme, initialMarkdown: "# Crashy\n")
        for _ in 0...2 {
            coordinator.webViewWebContentProcessDidTerminate(webView)
        }
        XCTAssertEqual(coordinator.webContentProcessRecoveryAttemptsForTesting, 2)
        XCTAssertFalse(coordinator.isShellLoadingForTesting)

        // Dragging the pane (detach while already blank) then re-entering must
        // NOT grant the crashing payload a fresh budget or reload it.
        coordinator.handleViewLeftWindow()
        coordinator.handleViewReenteredWindow()

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

    func testMarkdownRenderKeepsVisibleHeadingPositionAfterContentUpdate() async throws {
        let frame = NSRect(x: 0, y: 0, width: 720, height: 360)
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
            baseURL: FileManager.default.temporaryDirectory.appendingPathComponent("scroll.md")
        )
        await fulfillment(of: [loaded], timeout: 5)
        if let error = loadDelegate.error {
            throw error
        }

        try await renderMarkdown(scrollSmokeMarkdown(extraBeforeSection20: false), in: webView)
        let before = try await evaluateScrollSnapshot(
            """
            (function() {
              var scroller = document.scrollingElement || document.documentElement;
              var heading = document.getElementById('section-20');
              document.documentElement.style.scrollBehavior = 'auto';
              window.scrollTo(0, heading.offsetTop - 48);
              return {
                top: heading.getBoundingClientRect().top,
                y: window.scrollY || scroller.scrollTop,
                max: scroller.scrollHeight - scroller.clientHeight
              };
            })();
            """,
            in: webView
        )

        XCTAssertGreaterThan(before["max"] ?? 0, 1_000)

        try await renderMarkdown(scrollSmokeMarkdown(extraBeforeSection20: true), in: webView)
        let after = try await evaluateScrollSnapshot(
            """
            (function() {
              var scroller = document.scrollingElement || document.documentElement;
              var heading = document.getElementById('section-20');
              return {
                top: heading.getBoundingClientRect().top,
                y: window.scrollY || scroller.scrollTop,
                max: scroller.scrollHeight - scroller.clientHeight
              };
            })();
            """,
            in: webView
        )

        XCTAssertGreaterThan(after["max"] ?? 0, before["max"] ?? 0)
        XCTAssertEqual(after["top"] ?? .greatestFiniteMagnitude, before["top"] ?? 0, accuracy: 6)
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
        let restoredHTTPButton = try await waitForRemoteImageButtonRevert(
            alt: "HTTP remote",
            expectedText: expectedCopyURLButton,
            in: webView
        )
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

    private func renderMarkdown(_ markdown: String, in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try XCTUnwrap(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.__cmuxRenderMarkdown(\(literal)[0]);")
    }

    private func evaluateScrollSnapshot(_ script: String, in webView: WKWebView) async throws -> [String: Double] {
        let result = try await webView.evaluateJavaScript(script)
        let raw = try XCTUnwrap(result as? [String: Any])
        var snapshot: [String: Double] = [:]
        for (key, value) in raw {
            if let number = value as? NSNumber {
                snapshot[key] = number.doubleValue
            }
        }
        return snapshot
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

    private func waitForRemoteImageButtonRevert(
        alt: String,
        expectedText: String,
        in webView: WKWebView
    ) async throws -> [String: Any] {
        // The "Copied" label reverts to "Copy image URL" via a JS setTimeout in the
        // markdown viewer shell, which runs in a separate WebKit process. Poll the real
        // DOM transition instead of racing a fixed sleep against that timer.
        let deadline = Date().addingTimeInterval(8)
        var lastSnapshot: [String: Any] = [:]

        while Date() < deadline {
            let result = try await webView.evaluateJavaScript(
                """
                (function() {
                  var img = document.querySelector('img[alt="\(alt)"]');
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
            lastSnapshot = try XCTUnwrap(result as? [String: Any])
            if lastSnapshot["text"] as? String == expectedText,
               lastSnapshot["copied"] == nil || lastSnapshot["copied"] is NSNull {
                return lastSnapshot
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        throw NSError(
            domain: "MarkdownPanelTests",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "Timed out waiting for remote image button to revert to \(expectedText). Last snapshot: \(lastSnapshot)"
            ]
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

    private func scrollSmokeMarkdown(extraBeforeSection20: Bool) -> String {
        var lines: [String] = ["# Scroll Smoke", ""]
        for section in 1...36 {
            if section == 20, extraBeforeSection20 {
                for line in 1...12 {
                    lines.append("Inserted external edit line \(line), above the visible heading.")
                }
                lines.append("")
            }

            lines.append("## Section \(section)")
            lines.append("")
            for paragraph in 1...5 {
                lines.append(
                    "Paragraph \(paragraph) for section \(section). This gives the renderer enough height to exercise scroll restoration after an external file edit."
                )
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
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

    private static let onePixelPNGDataURI = "data:image/png;base64,\(onePixelPNG.base64EncodedString())"
}

private final class MarkdownShellLoadDelegate: NSObject, WKNavigationDelegate {
    let expectation: XCTestExpectation
    var error: Error?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        expectation.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        expectation.fulfill()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        expectation.fulfill()
    }
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
        finished = true
        lock.unlock()
        finishedExpectation.fulfill()
    }

    func didFailWithError(_ error: Error) {
        lock.lock()
        receivedError = error
        lock.unlock()
        finishedExpectation.fulfill()
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

private final class MarkdownRemoteImageHoldingSchemeHandler: NSObject, WKURLSchemeHandler {
    private var tasks: [ObjectIdentifier: WKURLSchemeTask] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        tasks[ObjectIdentifier(urlSchemeTask as AnyObject)] = urlSchemeTask
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks[ObjectIdentifier(urlSchemeTask as AnyObject)] = nil
    }

    func cancelOpenTasks() {
        let openTasks = Array(tasks.values)
        tasks.removeAll()
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        for task in openTasks {
            task.didFailWithError(error)
        }
    }
}
