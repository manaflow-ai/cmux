import CryptoKit
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
    func xctestProcessArmsCEFExitBypass() {
        #expect(CEFRuntimeSupport.isRunningUnderXCTest(environment: [
            "XCTestConfigurationFilePath": "/tmp/cmuxTests.xctestconfiguration"
        ]))
        #expect(!CEFRuntimeSupport.isRunningUnderXCTest(environment: [:]))
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
    func extensionDownloadsRequirePinnedSHA256Digests() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRoot
            .appendingPathComponent("Packages/macOS/CEFKit/scripts/fetch-extensions.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(script.contains("UBOL_SHA256="))
        #expect(script.contains("BITWARDEN_SHA256="))
        #expect(script.contains("shasum -a 256 -c"))
        #expect(script.range(of: "shasum -a 256 -c")!.lowerBound < script.range(of: "unzip -q")!.lowerBound)
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

    private func expectedExtensionID(_ directory: URL) -> String {
        let path = directory.absoluteURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
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
