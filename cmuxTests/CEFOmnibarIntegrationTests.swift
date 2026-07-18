import CryptoKit
import CEFKit
import CmuxCommandPalette
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("CEF omnibar integration")
struct CEFOmnibarIntegrationTests {
    @Test
    func xctestProcessSkipsCEFInitialization() {
        #expect(CEFRuntimeSupport.isRunningUnderXCTest(environment: [
            "XCTestConfigurationFilePath": "/tmp/cmuxTests.xctestconfiguration"
        ]))
        #expect(!CEFRuntimeSupport.isRunningUnderXCTest(environment: [:]))
        #expect(!CEFRuntimeSupport.shouldInitializeCEF(environment: [
            "XCTestConfigurationFilePath": "/tmp/cmuxTests.xctestconfiguration"
        ]))
        #expect(CEFRuntimeSupport.shouldInitializeCEF(environment: [:]))
    }

    @Test
    func typedNavigationUsesProfileHistoryStore() throws {
        let directory = temporaryDirectory(named: "typed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(
            fileURL: directory.appendingPathComponent("history.json")
        )
        let panel = CEFBrowserPanel(
            workspaceId: UUID(),
            historyStore: store
        )

        panel.navigate(to: "example.com/path")

        let entry = try #require(store.entries.first)
        #expect(entry.url == "https://example.com/path")
        #expect(entry.typedCount == 1)
    }

    @Test
    func chromeManagementURLKeepsOpaqueScheme() throws {
        let panel = CEFBrowserPanel(workspaceId: UUID())

        let url = try #require(panel.resolveNavigableURL(from: "chrome:extensions"))

        #expect(url.absoluteString == "chrome:extensions")
    }

    @Test
    func javascriptURLIsRejected() {
        let panel = CEFBrowserPanel(workspaceId: UUID())

        #expect(panel.resolveNavigableURL(from: "javascript:alert(document.cookie)") == nil)
    }

    @Test
    func plainTextResolvesAsSearchInsteadOfURL() {
        let panel = CEFBrowserPanel(workspaceId: UUID())

        #expect(panel.resolveNavigableURL(from: "weather today") == nil)
    }

    @Test
    func hiddenPaneHidesNativeHostBeforeBrowserCreation() {
        let panel = CEFBrowserPanel(workspaceId: UUID())

        panel.setVisibleInUI(false)

        #expect(panel.hostView.isHidden)
        #expect(!panel.isVisibleInUI)
    }

    @Test
    func staleCEFHostReleaseCannotHideReplacement() {
        let panel = CEFBrowserPanel(workspaceId: UUID())
        let staleOwner = UUID()
        let replacementOwner = UUID()

        panel.setVisibleInUI(true, ownerID: staleOwner)
        panel.setVisibleInUI(true, ownerID: replacementOwner)
        panel.releaseVisibilityOwner(staleOwner)

        #expect(panel.isVisibleInUI)
        #expect(!panel.hostView.isHidden)

        panel.releaseVisibilityOwner(replacementOwner)
        #expect(!panel.isVisibleInUI)
        #expect(panel.hostView.isHidden)
    }

    @Test
    func popupNavigationRoutesIntoOwnedChromiumPanel() {
        let panel = CEFBrowserPanel(workspaceId: UUID())

        panel.routePopupNavigation("https://example.com/oauth/callback")

        #expect(panel.currentURL == "https://example.com/oauth/callback")
    }

    @Test
    func hiddenDockReconcilesChromiumPanelVisibility() {
        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let panel = CEFBrowserPanel(workspaceId: store.workspaceId)
        store.panels[panel.id] = panel

        store.applyVisibility(to: panel)

        #expect(panel.hostView.isHidden)
        #expect(!panel.isVisibleInUI)
    }

    @Test
    func chromiumPanelMarksBrowserShortcutFocus() {
        let panel = CEFBrowserPanel(workspaceId: UUID())
        let context = ShortcutEventFocusContext(
            browserPanel: nil,
            omnibarPanel: panel,
            markdownPanel: nil,
            filePreviewTextEditorFocused: false,
            rightSidebarFocused: false,
            shortcutContext: ShortcutContext()
        )

        #expect(context.focusState.browser)
    }

    @Test
    func activeDockOmnibarWinsOverMainBrowser() throws {
        let dockPanel = CEFBrowserPanel(workspaceId: UUID())
        let mainPanel = CEFBrowserPanel(workspaceId: UUID())

        let resolved = try #require(preferredOmnibarPanel(
            activeDockPanel: dockPanel,
            mainPanel: mainPanel
        ))

        #expect(resolved.id == dockPanel.id)
    }

    @Test
    func addressBarExitHandoffRechecksLiveFocusOwner() {
        let originalPanel = CEFBrowserPanel(workspaceId: UUID())
        let replacementPanel = CEFBrowserPanel(workspaceId: UUID())
        var liveFocusedPanel: (any OmnibarHostingPanel)? = originalPanel
        let originalPanelStillOwnsFocus = {
            omnibarFocusOwnerMatches(
                panelId: originalPanel.id,
                focusedPanel: liveFocusedPanel
            )
        }

        #expect(originalPanelStillOwnsFocus())
        liveFocusedPanel = replacementPanel
        #expect(!originalPanelStillOwnsFocus())
    }

    @Test
    func focusedOmnibarLookupPrefersWindowDockStorage() throws {
        let dockPanel = CEFBrowserPanel(workspaceId: UUID())
        let workspacePanel = CEFBrowserPanel(workspaceId: UUID())

        let resolved = try #require(resolveFocusedOmnibarPanel(
            windowDockPanel: dockPanel,
            workspacePanel: workspacePanel
        ))

        #expect(resolved.id == dockPanel.id)
    }

    @Test
    func hiddenCEFPaneDismissesExtensionPopover() {
        #expect(shouldDismissCEFExtensionPopover(isVisibleInUI: false))
        #expect(!shouldDismissCEFExtensionPopover(isVisibleInUI: true))
    }

    @Test
    func omnibarPaletteCapabilityIsDistinctFromWebKitCapability() {
        #expect(CommandPaletteContextKeys.panelHasOmnibar != CommandPaletteContextKeys.panelIsBrowser)
    }

    @Test
    func cefHostsShareOneApplicationEventMonitor() {
        #expect(CEFBrowserHostCoordinator.usesSharedEventMonitor)
    }

    @Test
    func replacementCEFHostRegistrationSurvivesOldCoordinatorCleanup() async {
        let container = CEFBrowserContainerView(frame: .zero)
        var oldCoordinator: CEFBrowserHostCoordinator? = CEFBrowserHostCoordinator(
            containerView: container,
            presentationOwnerID: UUID(),
            onRequestPanelFocus: {}
        )
        let replacement = CEFBrowserHostCoordinator(
            containerView: container,
            presentationOwnerID: UUID(),
            onRequestPanelFocus: {}
        )

        oldCoordinator = nil
        await Task.yield()

        #expect(CEFBrowserHostCoordinator.hasRegistrationForTesting(container))
        _ = replacement
    }

    @Test
    func extensionPopoverRetainsControllerUntilCloseCallback() {
        let controller = CEFExtensionPopoverController()

        controller.beginClosingForTesting(waitingForPopoverClose: true)

        #expect(controller.isRetainedForClosingForTesting)
        controller.completePopoverCloseForTesting()
        #expect(!controller.isRetainedForClosingForTesting)
    }

    @Test
    func sessionSnapshotPreservesChromiumPanelURL() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let profileID = UUID()
        let panel = CEFBrowserPanel(
            workspaceId: workspace.id,
            profileID: profileID,
            initialURL: "https://example.com/session"
        )
        workspace.panels[panel.id] = panel
        workspace.panelTitles[panel.id] = panel.displayTitle
        let tabID = try #require(workspace.bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: "cefBrowser",
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: pane
        ))
        workspace.bindSurface(tabID, toPanelId: panel.id)

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(snapshot.panels.first { $0.id == panel.id })

        #expect(panelSnapshot.type == .cefBrowser)
        #expect(panelSnapshot.browser?.urlString == "https://example.com/session")
        #expect(panelSnapshot.browser?.profileID == profileID)
        #expect(panel.cefProfileName == profileID.uuidString.lowercased())
    }

    @Test
    func detachedChromiumPanelRebindsToDestinationWorkspace() throws {
        let source = Workspace()
        let sourcePane = try #require(source.bonsplitController.allPaneIds.first)
        let panel = CEFBrowserPanel(workspaceId: source.id)
        source.panels[panel.id] = panel
        source.panelTitles[panel.id] = panel.displayTitle
        let tabID = try #require(source.bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: "cefBrowser",
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: sourcePane
        ))
        source.bindSurface(tabID, toPanelId: panel.id)

        let detached = try #require(source.detachSurface(panelId: panel.id))
        let destination = Workspace()
        let destinationPane = try #require(destination.bonsplitController.allPaneIds.first)
        _ = try #require(destination.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        ))

        #expect(panel.workspaceId == destination.id)
        #expect(destination.panelSubscriptions[panel.id] != nil)
    }

    @Test
    func dockRoundTripPreservesChromiumSurfaceKind() throws {
        let source = Workspace()
        let sourcePane = try #require(source.bonsplitController.allPaneIds.first)
        let panel = CEFBrowserPanel(workspaceId: source.id)
        source.panels[panel.id] = panel
        source.panelTitles[panel.id] = panel.displayTitle
        let tabID = try #require(source.bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: "cefBrowser",
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: sourcePane
        ))
        source.bindSurface(tabID, toPanelId: panel.id)
        let detached = try #require(source.detachSurface(panelId: panel.id))
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { dock.closeAllPanels() }
        let dockPane = try #require(dock.bonsplitController.allPaneIds.first)

        _ = try #require(dock.attachDetachedSurface(detached, inPane: dockPane, focus: false))
        let roundTripped = try #require(dock.detachSurface(panelId: panel.id))

        #expect(roundTripped.kind == "cefBrowser")
    }

    @Test
    func chromiumTabBarNewTabCreatesChromiumSibling() throws {
        let workspace = Workspace()
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        let existingPanelIDs = Set(workspace.panels.keys)

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestNewTab: "cefBrowser",
            inPane: pane
        )

        let createdPanels = workspace.panels
            .filter { !existingPanelIDs.contains($0.key) }
            .map(\.value)
        #expect(createdPanels.count == 1)
        #expect(createdPanels.first is CEFBrowserPanel)
    }

    @Test
    func extensionDownloadsRequirePinnedSHA256Digests() throws {
        let temporary = temporaryDirectory(named: "extension-digest")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRoot
            .appendingPathComponent("Packages/macOS/CEFKit/scripts/fetch-extensions.sh")
        let fakeBin = temporary.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let payload = temporary.appendingPathComponent("corrupt.zip")
        try Data("not the pinned extension".utf8).write(to: payload)
        let unzipMarker = temporary.appendingPathComponent("unzip-ran")
        let fakeCurl = fakeBin.appendingPathComponent("curl")
        try """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then output="$2"; shift 2; else shift; fi
        done
        cp "$CEF_TEST_PAYLOAD" "$output"
        """.write(to: fakeCurl, atomically: true, encoding: .utf8)
        let fakeUnzip = fakeBin.appendingPathComponent("unzip")
        try """
        #!/bin/sh
        touch "$CEF_TEST_UNZIP_MARKER"
        exit 99
        """.write(to: fakeUnzip, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCurl.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeUnzip.path)
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        process.standardError = stderr
        process.standardOutput = Pipe()
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "CEFKIT_EXTENSIONS_DIR": temporary.appendingPathComponent("extensions").path,
            "CEFKIT_CURL_BIN": fakeCurl.path,
            "CEFKIT_UNZIP_BIN": fakeUnzip.path,
            "CEF_TEST_PAYLOAD": payload.path,
            "CEF_TEST_UNZIP_MARKER": unzipMarker.path,
        ]

        try process.run()
        process.waitUntilExit()
        let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(process.terminationStatus != 0)
        #expect(errorOutput.contains("SHA-256 mismatch"))
        #expect(!FileManager.default.fileExists(atPath: unzipMarker.path))
    }

    @Test
    func cachedExtensionContentIsRevalidatedBeforeReuse() throws {
        let temporary = temporaryDirectory(named: "cached-extension-digest")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRoot
            .appendingPathComponent("Packages/macOS/CEFKit/scripts/fetch-extensions.sh")
        let extensionRoot = temporary.appendingPathComponent("extensions", isDirectory: true)
        let cached = extensionRoot.appendingPathComponent("ublock-origin-lite", isDirectory: true)
        try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cached.appendingPathComponent("manifest.json"))
        try Data("modified".utf8).write(to: cached.appendingPathComponent("background.js"))
        try "2026.711.25".write(
            to: cached.appendingPathComponent(".fetched-version"),
            atomically: true,
            encoding: .utf8
        )
        try "invalid-cached-digest".write(
            to: cached.appendingPathComponent(".fetched-content-sha256"),
            atomically: true,
            encoding: .utf8
        )
        let requestedURL = temporary.appendingPathComponent("requested-url")
        let fakeCurl = temporary.appendingPathComponent("curl")
        try """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then output="$2"; shift 2
          else url="$1"; shift
          fi
        done
        printf '%s' "$url" > "$CEF_TEST_REQUESTED_URL"
        printf 'corrupt' > "$output"
        """.write(to: fakeCurl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCurl.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "CEFKIT_EXTENSIONS_DIR": extensionRoot.path,
            "CEFKIT_CURL_BIN": fakeCurl.path,
            "CEF_TEST_REQUESTED_URL": requestedURL.path,
        ]

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        let fetchedURL = try String(contentsOf: requestedURL, encoding: .utf8)
        #expect(fetchedURL.contains("uBOLite_2026.711.25.chromium.zip"))
    }

    @Test
    func extensionBundlingAllowsEmptyOptionalDirectory() throws {
        let temporary = temporaryDirectory(named: "empty-extension-bundle")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRoot.appendingPathComponent("scripts/copy-cef-runtime-dev.sh")
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        let destination = temporary.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "CEFKIT_COPY_EXTENSIONS_ONLY": "1",
            "CEFKIT_EXTENSION_SOURCE_DIR": source.path,
            "CEFKIT_EXTENSION_DESTINATION_DIR": destination.path,
        ]

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test
    func completedLoadingTransitionRecordsVisit() throws {
        let directory = temporaryDirectory(named: "visit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(
            fileURL: directory.appendingPathComponent("history.json")
        )
        let panel = CEFBrowserPanel(
            workspaceId: UUID(),
            historyStore: store
        )
        panel.currentURL = "https://example.com/finished"
        panel.applyLoadingState(isLoading: true, canGoBack: false, canGoForward: false)

        panel.applyLoadingState(isLoading: false, canGoBack: true, canGoForward: false)

        let entry = try #require(store.entries.first)
        #expect(entry.url == "https://example.com/finished")
        #expect(entry.visitCount == 1)
    }

    @Test
    func stagedManifestProducesChromiumIDLocalizedNameAndPopup() throws {
        let directory = temporaryDirectory(named: "extension")
        defer { try? FileManager.default.removeItem(at: directory) }
        let localeDirectory = directory
            .appendingPathComponent("_locales", isDirectory: true)
            .appendingPathComponent("en", isDirectory: true)
        try FileManager.default.createDirectory(
            at: localeDirectory,
            withIntermediateDirectories: true
        )
        try Data(
            """
            {
              "manifest_version": 3,
              "name": "__MSG_extensionName__",
              "default_locale": "en",
              "action": { "default_popup": "popup/index.html" }
            }
            """.utf8
        ).write(to: directory.appendingPathComponent("manifest.json"))
        try Data(
            #"{"extensionName":{"message":"Example Extension"}}"#.utf8
        ).write(to: localeDirectory.appendingPathComponent("messages.json"))

        let action = try #require(CEFExtensionActionLoader().load(from: [directory]).first)

        #expect(action.name == "Example Extension")
        #expect(action.popupURL.absoluteString == "chrome-extension://\(expectedExtensionID(directory))/popup/index.html")
    }

    @Test
    func manifestKeyDeterminesChromiumExtensionID() throws {
        let directory = temporaryDirectory(named: "keyed-extension")
        defer { try? FileManager.default.removeItem(at: directory) }
        let publicKey = Data("stable-public-key".utf8)
        try Data(
            """
            {
              "manifest_version": 3,
              "name": "Keyed Extension",
              "key": "\(publicKey.base64EncodedString())",
              "action": { "default_popup": "popup.html" }
            }
            """.utf8
        ).write(to: directory.appendingPathComponent("manifest.json"))

        let action = try #require(CEFExtensionActionLoader().load(from: [directory]).first)

        #expect(action.id == expectedExtensionID(publicKey))
        #expect(action.popupURL.absoluteString == "chrome-extension://\(expectedExtensionID(publicKey))/popup.html")
    }

    private func expectedExtensionID(_ directory: URL) -> String {
        let path = directory.absoluteURL.standardizedFileURL.path
        return expectedExtensionID(Data(path.utf8))
    }

    private func expectedExtensionID(_ source: Data) -> String {
        let digest = SHA256.hash(data: source)
        let alphabet = Array("abcdefghijklmnop")
        return digest.prefix(16).flatMap { byte in
            [alphabet[Int(byte >> 4)], alphabet[Int(byte & 0x0f)]]
        }
        .map(String.init)
        .joined()
    }

    private func temporaryDirectory(named suffix: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CEFOmnibarIntegrationTests-\(suffix)-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
