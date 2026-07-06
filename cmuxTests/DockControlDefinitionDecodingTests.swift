import Foundation
import CmuxSidebar
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Back-compat + new-schema coverage for `DockControlDefinition` decoding.
///
/// The Dock now reuses the main-area panel system (terminals *and* browsers),
/// so the config schema gained an optional `type`/`url`. Existing terminal-only
/// `dock.json` files must keep decoding unchanged.
@Suite("Dock control definition decoding", .serialized)
struct DockControlDefinitionDecodingTests {
    private func decode(_ json: String) throws -> DockControlDefinition {
        try JSONDecoder().decode(DockControlDefinition.self, from: Data(json.utf8))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-dock-config-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func v2Result(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(raw.data(using: .utf8))
        let envelope = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        if envelope["ok"] as? Bool != true {
            Issue.record("Expected \(method) to succeed: \(raw)")
        }
        return try #require(envelope["result"] as? [String: Any])
    }

    @MainActor
    private func terminalPanel(in store: DockSplitStore, panelId: UUID) throws -> TerminalPanel {
        let tabId = try #require(store.surfaceId(forPanelId: panelId))
        return try #require(store.panel(for: tabId) as? TerminalPanel)
    }

    @Test("Legacy terminal config decodes unchanged")
    func legacyTerminalDecodes() throws {
        let control = try decode(#"{"id":"git","title":"Git","command":"lazygit","cwd":".","height":300}"#)
        #expect(control.id == "git")
        #expect(control.title == "Git")
        #expect(control.kind == .terminal)
        #expect(control.command == "lazygit")
        #expect(control.url == nil)
        #expect(control.cwd == ".")
        #expect(control.height == 300)
    }

    @Test("Terminal config without a title falls back to id")
    func terminalTitleFallsBackToId() throws {
        let control = try decode(#"{"id":"logs","command":"tail -f log"}"#)
        #expect(control.title == "logs")
        #expect(control.kind == .terminal)
    }

    @Test("Terminal config missing command throws")
    func terminalMissingCommandThrows() {
        #expect(throws: (any Error).self) {
            _ = try decode(#"{"id":"git","title":"Git"}"#)
        }
    }

    @Test("Browser config decodes with url and no command")
    func browserDecodes() throws {
        let control = try decode(#"{"id":"docs","title":"Docs","type":"browser","url":"https://example.com"}"#)
        #expect(control.id == "docs")
        #expect(control.kind == .browser)
        #expect(control.url == "https://example.com")
        #expect(control.command == nil)
    }

    @Test("Browser config missing url throws")
    func browserMissingURLThrows() {
        #expect(throws: (any Error).self) {
            _ = try decode(#"{"id":"docs","type":"browser"}"#)
        }
    }

    @Test("Unknown control type throws")
    func unknownTypeThrows() {
        #expect(throws: (any Error).self) {
            _ = try decode(#"{"id":"x","type":"markdown","command":"echo"}"#)
        }
    }

    @Test("Blank id throws")
    func blankIDThrows() {
        #expect(throws: (any Error).self) {
            _ = try decode(#"{"id":"   ","command":"echo"}"#)
        }
    }

    @Test("Terminal entries re-encode without a type key (stable trust fingerprint)")
    func terminalReencodeOmitsType() throws {
        let control = DockControlDefinition(id: "git", title: "Git", command: "lazygit", height: 300)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(data: try encoder.encode(control), encoding: .utf8) ?? ""
        #expect(!encoded.contains("\"type\""))
        #expect(!encoded.contains("\"url\""))
        #expect(encoded.contains("\"command\":\"lazygit\""))
    }

    @Test("Terminal entries without command fail to encode")
    func terminalReencodeMissingCommandThrows() {
        let control = DockControlDefinition(id: "git", title: "Git")
        #expect(throws: (any Error).self) {
            _ = try JSONEncoder().encode(control)
        }
    }

    @Test("Browser entries re-encode with type and url")
    func browserReencodeIncludesTypeAndURL() throws {
        let control = DockControlDefinition(
            id: "docs",
            title: "Docs",
            kind: .browser,
            url: "https://example.com"
        )
        let encoded = String(data: try JSONEncoder().encode(control), encoding: .utf8) ?? ""
        #expect(encoded.contains("\"type\""))
        #expect(encoded.contains("\"url\""))
    }

    @Test("Browser entries without url fail to encode")
    func browserReencodeMissingURLThrows() {
        let control = DockControlDefinition(id: "docs", title: "Docs", kind: .browser)
        #expect(throws: (any Error).self) {
            _ = try JSONEncoder().encode(control)
        }
    }

    @Test("Mixed terminal + browser config file decodes")
    func mixedConfigFileDecodes() throws {
        let json = #"""
        {
          "controls": [
            {"id": "git", "title": "Git", "command": "lazygit"},
            {"id": "docs", "title": "Docs", "type": "browser", "url": "https://example.com"}
          ]
        }
        """#
        let file = try JSONDecoder().decode(DockConfigFile.self, from: Data(json.utf8))
        #expect(file.controls.count == 2)
        #expect(file.controls[0].kind == .terminal)
        #expect(file.controls[1].kind == .browser)
        #expect(file.controls[1].url == "https://example.com")
    }

    @Test("Project config identity follows the resolved dock file, not child cwd")
    @MainActor
    func projectConfigIdentityUsesResolvedDockFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cmuxDirectory = root.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: cmuxDirectory, withIntermediateDirectories: true)
        let dockConfig = cmuxDirectory.appendingPathComponent("dock.json", isDirectory: false)
        try #"{"controls":[{"id":"git","title":"Git","command":"lazygit"}]}"#
            .write(to: dockConfig, atomically: true, encoding: .utf8)

        let firstChild = root.appendingPathComponent("packages/app", isDirectory: true)
        let secondChild = root.appendingPathComponent("packages/web", isDirectory: true)
        try FileManager.default.createDirectory(at: firstChild, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondChild, withIntermediateDirectories: true)

        let firstIdentity = DockSplitStore.configIdentity(rootDirectory: firstChild.path)
        let secondIdentity = DockSplitStore.configIdentity(rootDirectory: secondChild.path)

        #expect(firstIdentity == secondIdentity)
        #expect(firstIdentity.sourcePath == dockConfig.standardizedFileURL.path)
        #expect(firstIdentity.baseDirectory == root.path)
    }

    @Test("No-config Dock identity changes do not require panel reload")
    @MainActor
    func noConfigIdentityChangesDoNotRequirePanelReload() throws {
        let firstRoot = try makeTemporaryDirectory()
        let secondRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        let firstIdentity = DockSplitStore.configIdentity(rootDirectory: firstRoot.path)
        let secondIdentity = DockSplitStore.configIdentity(rootDirectory: secondRoot.path)

        #expect(firstIdentity.sourcePath == nil)
        #expect(secondIdentity.sourcePath == nil)
        #expect(firstIdentity != secondIdentity)
        #expect(!secondIdentity.requiresPanelReload(comparedTo: firstIdentity))
    }

    @Test("Dock validation errors preserve localized descriptions without English prefix")
    func dockValidationErrorPreservesLocalizedDescription() {
        let message = "DockブラウザコントロールのURLは空にできません。"
        let error = NSError(
            domain: "cmux.dock",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: message]
        )

        #expect(DockSplitStore.configurationLoadErrorMessage(for: error) == message)
    }

    @Test("Project config parent traversal stops at the filesystem root")
    @MainActor
    func projectConfigParentTraversalStopsAtRoot() {
        #expect(DockSplitStore.parentDirectoryPath(for: "/") == nil)
        #expect(DockSplitStore.parentDirectoryPath(for: "/..") == nil)
        #expect(DockSplitStore.parentDirectoryPath(for: "/Users") == "/")
    }

    @Test("Dock surface creation without focus preserves the selected tab")
    @MainActor
    func newSurfaceWithoutFocusPreservesSelectedTab() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cmuxDirectory = root.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: cmuxDirectory, withIntermediateDirectories: true)
        let dockConfig = cmuxDirectory.appendingPathComponent("dock.json", isDirectory: false)
        try #"{"controls":[]}"#.write(to: dockConfig, atomically: true, encoding: .utf8)

        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { root.path })
        defer { store.closeAllPanels() }

        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let firstPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        let firstTabId = try #require(store.bonsplitController.selectedTab(inPane: rootPane)?.id)
        #expect(store.focusedPanelId == firstPanelId)

        let secondPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: false))

        #expect(secondPanelId != firstPanelId)
        #expect(store.bonsplitController.selectedTab(inPane: rootPane)?.id == firstTabId)
        #expect(store.focusedPanelId == firstPanelId)
    }

    @Test("Explicit Dock creation suppresses a late initial config seed")
    @MainActor
    func explicitCreationSuppressesLateInitialConfigSeed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { root.path })
        defer { store.closeAllPanels() }

        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let explicitPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        let configuredControl = DockControlDefinition(id: "configured", title: "Configured", command: "echo configured")
        let lateResolution = DockConfigResolution(
            controls: [configuredControl],
            sourceURL: nil,
            baseDirectory: root.path,
            isProjectSource: false
        )

        store.applyConfigurationLoadResult(.resolved(lateResolution), generation: 1, replacingPanels: false)

        #expect(store.bonsplitController.allTabIds.count == 1)
        #expect(store.containsPanel(explicitPanelId))
        #expect(store.focusedPanelId == explicitPanelId)
    }

    @Test("Root changes during pending Dock load ignore stale config results")
    @MainActor
    func rootChangeDuringPendingLoadIgnoresStaleConfigResult() throws {
        let oldRoot = try makeTemporaryDirectory()
        let newRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: oldRoot)
            try? FileManager.default.removeItem(at: newRoot)
        }

        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { newRoot.path })
        defer { store.closeAllPanels() }

        let staleGeneration = store.markConfigurationLoadInFlightForTesting(rootDirectory: oldRoot.path)
        store.setRootDirectory(newRoot.path)
        store.setActive(isVisible: true, mode: .dock)

        let staleResolution = DockConfigResolution(
            controls: [DockControlDefinition(id: "old", title: "Old", command: "echo old")],
            sourceURL: nil,
            baseDirectory: oldRoot.path,
            isProjectSource: false
        )
        store.applyConfigurationLoadResult(.resolved(staleResolution), generation: staleGeneration, replacingPanels: false)

        #expect(store.bonsplitController.allTabIds.isEmpty)
    }

    @Test("Workspace close confirmation includes Dock panels")
    @MainActor
    func workspaceCloseConfirmationIncludesDockPanels() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }

        let store = workspace.dockSplit
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let panelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        let terminalPanel = try terminalPanel(in: store, panelId: panelId)
        terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(true)
        defer { terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(nil) }

        #expect(workspace.needsConfirmClose())
    }

    @Test("surface.focus accepts Dock surface handles")
    @MainActor
    func surfaceFocusAcceptsDockSurfaceHandles() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        TerminalController.shared.setActiveTabManager(manager)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(manager.tabs.first)
        let store = workspace.dockSplit
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let firstPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        let secondPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: false))

        #expect(store.focusedPanelId == firstPanelId)

        let result = try v2Result(
            method: "surface.focus",
            params: ["surface_id": secondPanelId.uuidString]
        )

        #expect(result["window_id"] as? String == windowId.uuidString)
        #expect(result["workspace_id"] as? String == workspace.id.uuidString)
        #expect(result["surface_id"] as? String == secondPanelId.uuidString)
        #expect(store.focusedPanelId == secondPanelId)
    }

    @Test("Dock pane close prompt lists every tab that will close")
    @MainActor
    func dockPaneClosePromptListsEveryTabThatWillClose() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager()
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        defer { AppDelegate.shared = previousAppDelegate }

        let workspace = try #require(manager.tabs.first)
        defer { workspace.teardownAllPanels() }

        let store = workspace.dockSplit
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let dirtyPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        let cleanPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: false))
        let dirtyPanel = try terminalPanel(in: store, panelId: dirtyPanelId)
        let cleanPanel = try terminalPanel(in: store, panelId: cleanPanelId)
        dirtyPanel.surface.setNeedsConfirmCloseOverrideForTesting(true)
        cleanPanel.surface.setNeedsConfirmCloseOverrideForTesting(false)
        defer {
            dirtyPanel.surface.setNeedsConfirmCloseOverrideForTesting(nil)
            cleanPanel.surface.setNeedsConfirmCloseOverrideForTesting(nil)
        }

        var capturedPrompt: (title: String, message: String, acceptCmdD: Bool)?
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            capturedPrompt = (title, message, acceptCmdD)
            return false
        }

        #expect(!store.splitTabBar(store.bonsplitController, shouldClosePane: rootPane))
        for _ in 0..<10 where capturedPrompt == nil {
            await Task.yield()
        }

        let expectedMessage = String(
            format: String(
                localized: "dialog.closePane.message.other",
                defaultValue: "This will close %1$lld tabs in this pane:\n%2$@"
            ),
            locale: .current,
            Int64(2),
            "• Terminal\n• Terminal"
        )
        #expect(capturedPrompt?.title == String(localized: "dialog.closePane.title", defaultValue: "Close pane?"))
        #expect(capturedPrompt?.message == expectedMessage)
        #expect(capturedPrompt?.acceptCmdD == false)
    }

    @Test("Dock browser closes when WebKit requests close")
    @MainActor
    func dockBrowserClosesWhenWebViewRequestsClose() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { root.path },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }

        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let panelId = try #require(store.newSurface(kind: .browser, inPane: rootPane, url: URL(string: "https://example.com"), focus: true))
        let panel = try #require(store.browserPanel(for: panelId))

        panel.webViewDidRequestClose?()

        #expect(store.bonsplitController.allTabIds.isEmpty)
        #expect(!store.containsPanel(panelId))
    }
}
