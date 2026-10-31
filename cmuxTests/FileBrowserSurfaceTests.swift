import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct FileBrowserSurfaceTests {
    @Test
    func defaultSurfaceTabBarButtonsIncludeFileBrowserGitGraphAndHerd() {
        #expect(
            CmuxSurfaceTabBarButton.defaults.map(\.id) == [
                "cmux.newTerminal",
                "cmux.newBrowser",
                "cmux.splitRight",
                "cmux.splitDown",
                "cmux.newFileBrowser",
                "cmux.newGitGraph",
                "cmux.newHerd"
            ]
        )
    }

    @Test
    func gitGraphIsNotAcceptedAsAnUnrenderedSidebarMode() {
        #expect(RightSidebarMode.from(cliArgument: "git-graph") == nil)
        #expect(RightSidebarMode.from(cliArgument: "gitgraph") == nil)
        #expect(RightSidebarMode.from(cliArgument: "graph") == nil)
    }

    @Test
    func herdIsAConfiguredSurfaceActionNotAnUnrenderedSidebarMode() {
        #expect(RightSidebarMode.from(cliArgument: "herd") == nil)
        #expect(RightSidebarMode.from(cliArgument: "agents") == nil)
        #expect(CmuxSurfaceTabBarBuiltInAction(configID: "herd") == .newHerd)
        #expect(CmuxSurfaceTabBarBuiltInAction(configID: "agents") == .newHerd)
        #expect(CmuxSurfaceTabBarBuiltInAction.newHerd.resolvedConfigMetadata.title == "New Herd Tab")
    }

    @Test
    func gitGraphRemoteStateTransitionsBackToLocalForTheSameDirectory() {
        let model = GitGraphPanelModel()

        model.setDirectory("/tmp/repository", isRemote: true)
        #expect(model.state == .remoteUnsupported)

        model.reload()
        #expect(model.state == .remoteUnsupported)

        model.setDirectory("/tmp/repository", isRemote: false)
        #expect(model.state != .remoteUnsupported)
    }

    @Test
    func gitGraphAccessibilityLabelInterpolatesCommitMetadata() {
        let label = GitGraphAccessibility.commitLabel(
            subject: "Fix graph",
            author: "Ada",
            abbreviatedOID: "abc12345",
            locale: Locale(identifier: "en")
        )

        #expect(label == "Fix graph, Ada, abc12345")
        #expect(!label.contains("%1$@"))
    }

    @Test
    func repositoryToolDirectoryFailsClosedWithoutDirectoryProvenance() {
        let workspace = Workspace()
        workspace.currentDirectory = "   "

        #expect(workspace.repositoryToolDirectory(sourcePanelID: nil, rootDirectory: nil) == nil)
    }

    @Test
    func snapshotRoundTripsFileBrowserSourceAndToleratesLegacyPayload() throws {
        let sourcePanelID = UUID()
        let original = SessionRightSidebarToolPanelSnapshot(
            mode: .files,
            sourcePanelID: sourcePanelID,
            rootDirectory: "/tmp/project"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionRightSidebarToolPanelSnapshot.self, from: data)
        #expect(decoded.mode == .files)
        #expect(decoded.sourcePanelID == sourcePanelID)
        #expect(decoded.rootDirectory == "/tmp/project")

        let legacyData = #"{"mode":"files"}"#.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(SessionRightSidebarToolPanelSnapshot.self, from: legacyData)
        #expect(legacy.mode == .files)
        #expect(legacy.sourcePanelID == nil)
        #expect(legacy.rootDirectory == nil)
    }

    @Test
    func surfaceIsScopedToPaneAndReusesWithinPane() throws {
        let workspace = Workspace()
        let firstTerminalID = try #require(workspace.focusedPanelId)
        let firstPaneID = try #require(workspace.paneId(forPanelId: firstTerminalID))
        let secondTerminal = try #require(
            workspace.newTerminalSplit(from: firstTerminalID, orientation: .horizontal)
        )
        let secondPaneID = try #require(workspace.paneId(forPanelId: secondTerminal.id))
        workspace.panelDirectories[firstTerminalID] = "/tmp/first-pane"
        workspace.panelDirectories[secondTerminal.id] = "/tmp/second-pane"

        let firstBrowser = try #require(
            workspace.openOrFocusFileBrowserSurface(inPane: firstPaneID, focus: false)
        )
        let secondBrowser = try #require(
            workspace.openOrFocusFileBrowserSurface(inPane: secondPaneID, focus: false)
        )
        let reusedFirstBrowser = try #require(
            workspace.openOrFocusFileBrowserSurface(inPane: firstPaneID, focus: false)
        )

        #expect(firstBrowser.id != secondBrowser.id)
        #expect(firstBrowser.id == reusedFirstBrowser.id)
        #expect(firstBrowser.sourcePanelID == firstTerminalID)
        #expect(firstBrowser.rootDirectory == "/tmp/first-pane")
        #expect(secondBrowser.sourcePanelID == secondTerminal.id)
        #expect(secondBrowser.rootDirectory == "/tmp/second-pane")
        #expect(workspace.paneId(forPanelId: firstBrowser.id) == firstPaneID)
        #expect(workspace.paneId(forPanelId: secondBrowser.id) == secondPaneID)
        #expect(
            workspace.panels.values.compactMap { $0 as? RightSidebarToolPanel }
                .filter { $0.mode == .files }.count == 2
        )
    }

    @Test
    func openingFilesKeepsExplorerSurfaceAndPreservesEditorState() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let firstFile = fixtureDirectory.appendingPathComponent("first.swift")
        let secondFile = fixtureDirectory.appendingPathComponent("second.json")
        try "let value = 1\n".write(to: firstFile, atomically: true, encoding: .utf8)
        try "{}\n".write(to: secondFile, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        let terminalID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: terminalID))
        let browser = try #require(
            workspace.openOrFocusFileBrowserSurface(inPane: paneID, focus: false)
        )
        let panelCountBeforeSelection = workspace.panels.count

        browser.openFilePreview(firstFile.path)
        let firstPreview = try #require(browser.fileWorkspaceModel.previewPanel)
        firstPreview.updateTextContent("let value = 2\n")

        browser.openFilePreview(secondFile.path)
        #expect(browser.fileWorkspaceModel.previewPanel?.filePath == secondFile.path)
        #expect(workspace.panels.count == panelCountBeforeSelection)

        browser.openFilePreview(firstFile.path)
        #expect(browser.fileWorkspaceModel.previewPanel === firstPreview)
        #expect(browser.fileWorkspaceModel.previewPanel?.textContent == "let value = 2\n")
        #expect(browser.fileWorkspaceModel.previewPanel?.isDirty == true)
        #expect(workspace.panels.count == panelCountBeforeSelection)
    }

    @Test
    func staleRemoteFileCompletionCannotReplaceTheLatestSelection() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-file-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let olderFile = fixtureDirectory.appendingPathComponent("older.swift")
        let latestFile = fixtureDirectory.appendingPathComponent("latest.swift")
        try "let older = true\n".write(to: olderFile, atomically: true, encoding: .utf8)
        try "let latest = true\n".write(to: latestFile, atomically: true, encoding: .utf8)

        let model = FileWorkspaceModel()
        let workspaceID = UUID()
        let olderRequest = model.beginRemoteFileOpenRequest()
        let latestRequest = model.beginRemoteFileOpenRequest()

        #expect(model.completeRemoteFileOpenRequest(
            latestRequest,
            workspaceID: workspaceID,
            filePath: latestFile.path
        ))
        #expect(!model.completeRemoteFileOpenRequest(
            olderRequest,
            workspaceID: workspaceID,
            filePath: olderFile.path
        ))
        #expect(model.previewPanel?.filePath == latestFile.path)
    }

    @Test
    func gitGraphIsScopedToPaneAndReusesWithinPane() throws {
        let workspace = Workspace()
        let firstTerminalID = try #require(workspace.focusedPanelId)
        let firstPaneID = try #require(workspace.paneId(forPanelId: firstTerminalID))
        let secondTerminal = try #require(
            workspace.newTerminalSplit(from: firstTerminalID, orientation: .horizontal)
        )
        let secondPaneID = try #require(workspace.paneId(forPanelId: secondTerminal.id))
        workspace.panelDirectories[firstTerminalID] = "/tmp/first-repo"
        workspace.panelDirectories[secondTerminal.id] = "/tmp/second-repo"

        let firstGraph = try #require(
            workspace.openOrFocusGitGraphSurface(inPane: firstPaneID, focus: false)
        )
        let secondGraph = try #require(
            workspace.openOrFocusGitGraphSurface(inPane: secondPaneID, focus: false)
        )
        let reusedFirstGraph = try #require(
            workspace.openOrFocusGitGraphSurface(inPane: firstPaneID, focus: false)
        )

        #expect(firstGraph.id != secondGraph.id)
        #expect(firstGraph.id == reusedFirstGraph.id)
        #expect(firstGraph.sourcePanelID == firstTerminalID)
        #expect(firstGraph.rootDirectory == "/tmp/first-repo")
        #expect(secondGraph.sourcePanelID == secondTerminal.id)
        #expect(secondGraph.rootDirectory == "/tmp/second-repo")
        #expect(workspace.paneId(forPanelId: firstGraph.id) == firstPaneID)
        #expect(workspace.paneId(forPanelId: secondGraph.id) == secondPaneID)
    }

    @Test
    func herdReusesOneCrossWorkspaceControlSurface() throws {
        let workspace = Workspace()
        let firstTerminalID = try #require(workspace.focusedPanelId)
        let firstPaneID = try #require(workspace.paneId(forPanelId: firstTerminalID))
        let secondTerminal = try #require(
            workspace.newTerminalSplit(from: firstTerminalID, orientation: .horizontal)
        )
        let secondPaneID = try #require(workspace.paneId(forPanelId: secondTerminal.id))

        let firstHerd = try #require(
            workspace.openOrFocusHerdSurface(inPane: firstPaneID, focus: false)
        )
        let reusedHerd = try #require(
            workspace.openOrFocusHerdSurface(inPane: secondPaneID, focus: false)
        )

        #expect(firstHerd.id == reusedHerd.id)
        #expect(firstHerd.mode == .herd)
        #expect(workspace.paneId(forPanelId: firstHerd.id) == firstPaneID)
    }

    @Test
    func herdSnapshotProjectsAndPrioritizesAgentLifecycleAcrossWorkspaces() throws {
        let manager = TabManager()
        let firstWorkspace = try #require(manager.selectedWorkspace)
        let firstPanelID = try #require(firstWorkspace.focusedPanelId)
        firstWorkspace.setCustomTitle("Alpha")
        firstWorkspace.setAgentLifecycle(key: "codex", panelId: firstPanelID, lifecycle: .idle)

        let secondWorkspace = manager.addWorkspace(title: "Beta", select: true)
        let secondPanelID = try #require(secondWorkspace.focusedPanelId)
        secondWorkspace.setAgentLifecycle(key: "claude_code", panelId: secondPanelID, lifecycle: .needsInput)

        let snapshot = HerdPanelSnapshot.capture(tabManager: manager)

        #expect(snapshot.agentCount == 2)
        #expect(snapshot.needsInputCount == 1)
        #expect(snapshot.idleCount == 1)
        #expect(snapshot.lanes.map(\.lifecycle) == [.needsInput, .idle])
        #expect(snapshot.lanes.map(\.workspaceTitle) == ["Beta", "Alpha"])
        #expect(snapshot.lanes.first?.isFocused == true)
    }
}
