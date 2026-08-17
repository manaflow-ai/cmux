import CmuxSettings
import Foundation
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

    @MainActor
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
        #expect(control.showsBrowserChrome)
    }

    @Test("Browser config decodes chromeless toolbar policy")
    func chromelessBrowserDecodes() throws {
        let control = try decode(
            #"{"id":"dashboard","type":"browser","url":"http://127.0.0.1:8877/sidebar","chrome":false}"#
        )

        #expect(control.kind == .browser)
        #expect(!control.showsBrowserChrome)
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
        #expect(!encoded.contains("\"chrome\""))
    }

    @Test("Chromeless browser entries re-encode the opt-in field")
    func chromelessBrowserReencodeIncludesChrome() throws {
        let control = DockControlDefinition(
            id: "dashboard",
            title: "Dashboard",
            kind: .browser,
            url: "http://127.0.0.1:8877/sidebar",
            showsBrowserChrome: false
        )
        let encoded = String(data: try JSONEncoder().encode(control), encoding: .utf8) ?? ""

        #expect(encoded.contains("\"chrome\":false"))
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

    @Test("Chromeless Dock browser stays hidden across focus requests and session restore")
    @MainActor
    func chromelessBrowserBehaviorPersists() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { root.path },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }

        let generation = store.markConfigurationLoadInFlightForTesting(
            rootDirectory: root.path
        )
        let resolution = DockConfigResolution(
            controls: [
                DockControlDefinition(
                    id: "dashboard",
                    title: "Dashboard",
                    kind: .browser,
                    url: "http://127.0.0.1:8877/sidebar",
                    showsBrowserChrome: false
                )
            ],
            sourceURL: nil,
            baseDirectory: root.path,
            isProjectSource: false
        )
        store.applyConfigurationLoadResult(
            .resolved(resolution),
            generation: generation,
            replacingPanels: false
        )

        let panel = try #require(
            store.panels.values.compactMap { $0 as? BrowserPanel }.first
        )
        #expect(panel.chromeVisibility == .chromeless)
        #expect(!panel.isOmnibarVisible)
        #expect(panel.requestAddressBarFocus(selectionIntent: .selectAll) == nil)
        #expect(!panel.isOmnibarVisible)
        #expect(!panel.setOmnibarVisible(true))
        #expect(!panel.toggleOmnibarVisibility())
        #expect(panel.chromeVisibility == .chromeless)

        let snapshot = store.sessionSnapshot(includeScrollback: false)
        let encodedSnapshot = try JSONEncoder().encode(snapshot)
        let persistedSnapshot = try JSONDecoder().decode(
            SessionSplitContainerSnapshot.self,
            from: encodedSnapshot
        )
        #expect(
            persistedSnapshot.panels.first?.browser?.chromeVisibility ==
                .chromeless
        )

        let restoredStore = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { root.path },
            browserAvailabilityProvider: { true }
        )
        defer { restoredStore.closeAllPanels() }
        restoredStore.restoreSessionSnapshot(persistedSnapshot)

        let restoredPanel = try #require(
            restoredStore.panels.values.compactMap { $0 as? BrowserPanel }.first
        )
        #expect(restoredPanel.chromeVisibility == .chromeless)
        #expect(restoredPanel.requestAddressBarFocus() == nil)
        #expect(!restoredPanel.isOmnibarVisible)
    }

    @Test(
        "Configured Dock terminal follows live titles without replacing a custom name",
        arguments: [DockScope.workspace, DockScope.global]
    )
    @MainActor
    func configuredTerminalFollowsLiveTitlesWithoutReplacingCustomName(
        scope: DockScope
    ) throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let store: DockSplitStore
        switch scope {
        case .workspace:
            store = workspace.dockSplit
        case .global:
            store = manager.makeWindowDockStore(windowId: UUID())
        }
        defer {
            store.closeAllPanels()
            workspace.teardownAllPanels()
        }

        let resolution = DockConfigResolution(
            controls: [
                DockControlDefinition(
                    id: "agent",
                    title: "Agent",
                    command: "codex"
                )
            ],
            sourceURL: nil,
            baseDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            isProjectSource: false
        )
        store.applyConfigurationLoadResult(
            .resolved(resolution),
            generation: 0,
            replacingPanels: false
        )

        let tabID = try #require(store.bonsplitController.allTabIds.first)
        let terminal = try #require(store.panel(for: tabID) as? TerminalPanel)
        #expect(store.bonsplitController.tab(tabID)?.title == "Agent")

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: GhosttyTitleChange(
                tabId: store.workspaceId,
                surfaceId: terminal.id,
                title: "codex · starting",
                sourceSurfaceIdentifier: ObjectIdentifier(terminal.surface)
            ).userInfo
        )
        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: GhosttyTitleChange(
                tabId: store.workspaceId,
                surfaceId: terminal.id,
                title: "codex · issue 9337",
                sourceSurfaceIdentifier: ObjectIdentifier(terminal.surface)
            ).userInfo
        )

        let flushedSnapshot = store.sessionSnapshot(includeScrollback: false)
        let flushedPanel = try #require(
            flushedSnapshot.panels.first { $0.id == terminal.id }
        )
        #expect(flushedPanel.title == "codex · issue 9337")
        #expect(terminal.displayTitle == "codex · issue 9337")
        #expect(store.bonsplitController.tab(tabID)?.title == "codex · issue 9337")

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: GhosttyTitleChange(
                tabId: store.workspaceId,
                surfaceId: terminal.id,
                title: "zsh",
                sourceSurfaceIdentifier: ObjectIdentifier(terminal.surface)
            ).userInfo
        )

        store.flushPendingTerminalTitleUpdates()
        #expect(terminal.displayTitle == "zsh")
        #expect(store.bonsplitController.tab(tabID)?.title == "zsh")

        store.bonsplitController.updateTab(
            tabID,
            title: "Pinned agent",
            hasCustomTitle: true
        )
        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: GhosttyTitleChange(
                tabId: store.workspaceId,
                surfaceId: terminal.id,
                title: "claude · issue 9337",
                sourceSurfaceIdentifier: ObjectIdentifier(terminal.surface)
            ).userInfo
        )

        store.flushPendingTerminalTitleUpdates()
        #expect(terminal.displayTitle == "claude · issue 9337")
        #expect(store.bonsplitController.tab(tabID)?.title == "Pinned agent")
    }

    @Test("Window Dock title routing retains every live window store")
    @MainActor
    func windowDockTitleRoutingRetainsEveryLiveStore() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let firstStore = manager.makeWindowDockStore(windowId: UUID())
        let secondStore = manager.makeWindowDockStore(windowId: UUID())
        defer {
            firstStore.closeAllPanels()
            secondStore.closeAllPanels()
            workspace.teardownAllPanels()
        }

        for (store, liveTitle) in [
            (firstStore, "codex · first window Dock"),
            (secondStore, "codex · second window Dock"),
        ] {
            let paneID = try #require(
                store.bonsplitController.allPaneIds.first
            )
            let panelID = try #require(store.newSurface(
                kind: .terminal,
                inPane: paneID,
                workingDirectory: "/tmp",
                focus: false
            ))
            let terminal = try #require(
                store.panels[panelID] as? TerminalPanel
            )
            let tabID = try #require(
                store.surfaceId(forPanelId: panelID)
            )

            NotificationCenter.default.post(
                name: .ghosttyDidSetTitle,
                object: nil,
                userInfo: GhosttyTitleChange(
                    tabId: store.workspaceId,
                    surfaceId: panelID,
                    title: liveTitle,
                    sourceSurfaceIdentifier: ObjectIdentifier(terminal.surface)
                ).userInfo
            )
            store.flushPendingTerminalTitleUpdates()

            #expect(terminal.displayTitle == liveTitle)
            #expect(store.bonsplitController.tab(tabID)?.title == liveTitle)
        }
    }

    @Test("Dock terminal title bursts use the configured coalescing delay")
    @MainActor
    func terminalTitleBurstsUseConfiguredCoalescingDelay() throws {
        let defaultsName = "DockTitleCoalescing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(
            true,
            for: catalog.terminal.titleUpdateCoalescingEnabled
        )
        settings.set(
            250,
            for: catalog.terminal.titleUpdateCoalescingMilliseconds
        )
        let scheduler = ManualTitleCoalescerScheduler()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { "/tmp" },
            terminalTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        defer { store.closeAllPanels() }

        let paneID = try #require(store.bonsplitController.allPaneIds.first)
        let panelID = try #require(
            store.newSurface(
                kind: .terminal,
                inPane: paneID,
                workingDirectory: "/tmp",
                focus: false
            )
        )
        let tabID = try #require(store.surfaceId(forPanelId: panelID))
        let terminal = try #require(store.panels[panelID] as? TerminalPanel)

        for title in ["codex · starting", "codex · latest"] {
            #expect(store.applyTerminalTitleChange(GhosttyTitleChange(
                tabId: store.workspaceId,
                surfaceId: panelID,
                title: title,
                sourceSurfaceIdentifier: ObjectIdentifier(terminal.surface)
            )))
        }

        #expect(scheduler.delays == [0.25])
        #expect(terminal.displayTitle != "codex · latest")
        scheduler.fire(at: 0)
        #expect(terminal.displayTitle == "codex · latest")
        #expect(store.bonsplitController.tab(tabID)?.title == "codex · latest")
    }

    @Test("Pending Dock title is rejected after the retained terminal advances lifecycle")
    @MainActor
    func pendingTerminalTitleIsRejectedAfterHibernationLifecycleAdvance() throws {
        let defaultsName = "DockTitleHibernation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(250, for: catalog.terminal.titleUpdateCoalescingMilliseconds)
        let scheduler = ManualTitleCoalescerScheduler()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { "/tmp" },
            terminalTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        defer { store.closeAllPanels() }

        let paneID = try #require(store.bonsplitController.allPaneIds.first)
        let panelID = try #require(store.newSurface(
            kind: .terminal,
            inPane: paneID,
            workingDirectory: "/tmp",
            focus: false
        ))
        let tabID = try #require(store.surfaceId(forPanelId: panelID))
        let terminal = try #require(store.panels[panelID] as? TerminalPanel)
        let originalLifecycleID = terminal.surface.terminalLifecycleId
        let staleTitle = "codex · retired child"

        #expect(store.applyTerminalTitleChange(GhosttyTitleChange(
            tabId: store.workspaceId,
            surfaceId: panelID,
            title: staleTitle,
            sourceSurfaceIdentifier: ObjectIdentifier(terminal.surface)
        )))
        #expect(scheduler.delays == [0.25])
        #expect(terminal.displayTitle != staleTitle)

        #expect(terminal.surface.suspendRuntimeSurfaceForAgentHibernation(
            reason: "test.pendingDockTitle"
        ))
        #expect(terminal.surface.terminalLifecycleId != originalLifecycleID)

        scheduler.fire(at: 0)

        #expect(terminal.displayTitle != staleTitle)
        #expect(store.bonsplitController.tab(tabID)?.title != staleTitle)
    }

    @Test(
        "Transferred custom Dock title survives later live terminal titles",
        arguments: [false, true]
    )
    @MainActor
    func transferredCustomTitleSurvivesLiveTerminalTitle(
        attachesBySplitting: Bool
    ) throws {
        let source = Workspace()
        defer { source.teardownAllPanels() }
        let panelID = try #require(source.focusedPanelId)
        #expect(source.setPanelCustomTitle(panelId: panelID, title: "Pinned agent"))
        let detached = try #require(source.detachSurface(panelId: panelID))
        #expect(detached.customTitle == "Pinned agent")

        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let store = workspace.dockSplit
        defer {
            store.closeAllPanels()
            workspace.teardownAllPanels()
        }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let attachedPanelID: UUID?
        if attachesBySplitting {
            attachedPanelID = store.attachDetachedSurface(
                detached,
                bySplitting: rootPane,
                orientation: .horizontal,
                insertFirst: false,
                focus: false
            )
        } else {
            attachedPanelID = store.attachDetachedSurface(
                detached,
                inPane: rootPane,
                focus: false
            )
        }
        #expect(attachedPanelID == panelID)

        let tabID = try #require(store.surfaceId(forPanelId: panelID))
        let terminal = try #require(store.panel(for: tabID) as? TerminalPanel)
        #expect(store.bonsplitController.tab(tabID)?.title == "Pinned agent")
        #expect(store.bonsplitController.tab(tabID)?.hasCustomTitle == true)

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: GhosttyTitleChange(
                tabId: store.workspaceId,
                surfaceId: terminal.id,
                title: "codex · transferred",
                sourceSurfaceIdentifier: ObjectIdentifier(terminal.surface)
            ).userInfo
        )

        store.flushPendingTerminalTitleUpdates()
        #expect(terminal.displayTitle == "codex · transferred")
        #expect(store.bonsplitController.tab(tabID)?.title == "Pinned agent")
        #expect(store.bonsplitController.tab(tabID)?.hasCustomTitle == true)

        store.bonsplitController.updateTab(
            tabID,
            title: "Renamed agent",
            hasCustomTitle: true
        )
        let renamedSnapshot = store.sessionSnapshot(includeScrollback: false)
        let renamedPanel = try #require(
            renamedSnapshot.panels.first { $0.id == panelID }
        )
        #expect(renamedPanel.title == "Renamed agent")
        #expect(renamedPanel.customTitle == "Renamed agent")
        #expect(renamedPanel.customTitleSource == .user)

        store.bonsplitController.updateTab(
            tabID,
            title: terminal.displayTitle,
            hasCustomTitle: false
        )
        let automaticSnapshot = store.sessionSnapshot(includeScrollback: false)
        let automaticPanel = try #require(
            automaticSnapshot.panels.first { $0.id == panelID }
        )
        #expect(automaticPanel.title == "codex · transferred")
        #expect(automaticPanel.customTitle == nil)
        #expect(automaticPanel.customTitleSource == nil)
        #expect(automaticPanel.customTitle != "Pinned agent")

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: GhosttyTitleChange(
                tabId: store.workspaceId,
                surfaceId: terminal.id,
                title: "claude · before detach",
                sourceSurfaceIdentifier: ObjectIdentifier(terminal.surface)
            ).userInfo
        )
        let detachedFromDock = try #require(
            store.detachSurface(panelId: panelID)
        )
        defer { detachedFromDock.panel.close() }
        #expect(detachedFromDock.title == "claude · before detach")
        #expect(detachedFromDock.cachedTitle == "claude · before detach")
        #expect(detachedFromDock.customTitle == nil)
        #expect(detachedFromDock.restoredPanelTitleBoundary == nil)

        terminal.updateTitle("claude · after detach")
        let tablessMetadata = store.resolvedDockTitleMetadata(
            panel: terminal,
            transfer: detachedFromDock,
            tab: nil
        )
        #expect(tablessMetadata.title == "claude · after detach")
        #expect(tablessMetadata.cachedTitle == "claude · after detach")
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
        let resumeBinding = SurfaceResumeBindingSnapshot(
            name: "tmux",
            kind: "tmux",
            command: "tmux attach-session -t dock-cancelled-pane",
            cwd: "/tmp",
            checkpointId: "dock-cancelled-pane",
            source: "process-detected",
            autoResume: true,
            updatedAt: 1_999_999_999
        )
        store.surfaceResumeBindingsByPanelId[dirtyPanelId] = resumeBinding
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
        #expect(store.containsPanel(dirtyPanelId))
        #expect(store.surfaceResumeBindingsByPanelId[dirtyPanelId] == resumeBinding)
    }

    @Test("Cancelled Dock tab close preserves its live resume binding")
    @MainActor
    func cancelledDockTabClosePreservesResumeBinding() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            defer {
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            let store = workspace.dockSplit
            let rootPane = try #require(
                store.bonsplitController.allPaneIds.first
            )
            let panelId = try #require(
                store.newSurface(
                    kind: .terminal,
                    inPane: rootPane,
                    focus: true
                )
            )
            let terminal = try terminalPanel(
                in: store,
                panelId: panelId
            )
            terminal.surface.setNeedsConfirmCloseOverrideForTesting(true)
            defer {
                terminal.surface.setNeedsConfirmCloseOverrideForTesting(nil)
            }

            let resumeBinding = SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach-session -t dock-cancelled-tab",
                cwd: "/tmp",
                checkpointId: "dock-cancelled-tab",
                source: "process-detected",
                autoResume: true,
                updatedAt: 1_999_999_999
            )
            store.surfaceResumeBindingsByPanelId[panelId] = resumeBinding

            let promptHandled = AsyncStream<Void>.makeStream()
            var promptCount = 0
            manager.confirmCloseHandler = { _, _, _ in
                promptCount += 1
                promptHandled.continuation.yield()
                promptHandled.continuation.finish()
                return false
            }

            #expect(!store.closePanel(panelId))
            for await _ in promptHandled.stream {
                break
            }

            #expect(promptCount == 1)
            #expect(store.containsPanel(panelId))
            #expect(
                store.surfaceResumeBindingsByPanelId[panelId] ==
                    resumeBinding
            )
        }
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

    private final class ManualTitleCoalescerScheduler {
        private struct PendingFlush {
            var isCancelled = false
            let action: @MainActor () -> Void
        }

        private var pendingFlushes: [PendingFlush] = []
        private(set) var delays: [TimeInterval] = []

        @MainActor
        func schedule(
            delay: TimeInterval,
            action: @escaping @MainActor () -> Void
        ) -> NotificationBurstCoalescer.Cancellation {
            let index = pendingFlushes.count
            delays.append(delay)
            pendingFlushes.append(PendingFlush(action: action))
            return { [weak self] in
                self?.pendingFlushes[index].isCancelled = true
            }
        }

        @MainActor
        func fire(at index: Int) {
            guard pendingFlushes.indices.contains(index),
                  !pendingFlushes[index].isCancelled else {
                return
            }
            pendingFlushes[index].action()
        }
    }
}
