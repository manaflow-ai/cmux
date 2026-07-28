import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CmuxConfigActionCatalogDirectoryIndexTests {
    private let globalKey = CmuxConfigStore.actionCatalogCacheKey(startingFrom: nil)

    @Test
    func hotPanelEventChangesOneOfOneThousandContributions() throws {
        let workspaceID = UUID()
        let panelIDs = (0..<1_000).map { _ in UUID() }
        let panelKeys = Dictionary(uniqueKeysWithValues: panelIDs.enumerated().map { index, panelID in
            (panelID, "/project/\(index)")
        })
        var index = CmuxConfigActionCatalogDirectoryIndex(globalKey: globalKey)
        index.replaceWorkspace(
            workspaceID: workspaceID,
            workspaceKey: "/workspace",
            panelKeys: panelKeys
        )
        #expect(index.contributionCount == 1_002)

        let targetPanelID = panelIDs[517]
        let source = CmuxConfigActionCatalogDirectorySource.panel(
            workspaceID: workspaceID,
            panelID: targetPanelID
        )
        let mutation = index.replaceContribution(source: source, key: "/moved")

        #expect(mutation.changedSources == [source])
        #expect(mutation.inactiveKeys == ["/project/517"])
        #expect(mutation.newlyActiveKeys == ["/moved"])
        #expect(index.contributionCount == 1_002)
        #expect(index.key(for: source) == "/moved")
        #expect(index.referenceCount(for: "/project/516") == 1)
        #expect(index.referenceCount(for: "/project/518") == 1)
    }

    @Test
    func sharedKeyRemainsUntilItsLastPanelMoves() {
        let workspaceID = UUID()
        let firstPanelID = UUID()
        let secondPanelID = UUID()
        let firstSource = CmuxConfigActionCatalogDirectorySource.panel(
            workspaceID: workspaceID,
            panelID: firstPanelID
        )
        let secondSource = CmuxConfigActionCatalogDirectorySource.panel(
            workspaceID: workspaceID,
            panelID: secondPanelID
        )
        var index = CmuxConfigActionCatalogDirectoryIndex(globalKey: globalKey)
        index.replaceWorkspace(
            workspaceID: workspaceID,
            workspaceKey: "/workspace",
            panelKeys: [firstPanelID: "/shared", secondPanelID: "/shared"]
        )
        #expect(index.referenceCount(for: "/shared") == 2)

        let firstMove = index.replaceContribution(source: firstSource, key: "/first")
        #expect(firstMove.inactiveKeys.isEmpty)
        #expect(index.referenceCount(for: "/shared") == 1)

        let secondMove = index.replaceContribution(source: secondSource, key: "/second")
        #expect(secondMove.inactiveKeys == ["/shared"])
        #expect(index.referenceCount(for: "/shared") == 0)
    }

    @Test
    func workspaceSnapshotNormalizesSourceOwnershipSwap() {
        let workspaceID = UUID()
        let panelID = UUID()
        var index = CmuxConfigActionCatalogDirectoryIndex(globalKey: globalKey)
        index.replaceWorkspace(
            workspaceID: workspaceID,
            workspaceKey: "/workspace",
            panelKeys: [panelID: "/panel"]
        )

        let mutation = index.replaceWorkspace(
            workspaceID: workspaceID,
            workspaceKey: "/panel",
            panelKeys: [panelID: "/workspace"]
        )

        #expect(mutation.inactiveKeys.isEmpty)
        #expect(mutation.newlyActiveKeys.isEmpty)
        #expect(index.referenceCount(for: "/workspace") == 1)
        #expect(index.referenceCount(for: "/panel") == 1)
    }

    @Test
    func terminalRequestedDirectorySurvivesWorkspaceDirectoryChange() throws {
        let panelDirectory = "/requested-panel"
        let workspace = Workspace(workingDirectory: panelDirectory)
        let panelID = try #require(workspace.focusedPanelId)
        var index = CmuxConfigActionCatalogDirectoryIndex(globalKey: globalKey)
        reconcile(workspace, into: &index)
        let panelSource = CmuxConfigActionCatalogDirectorySource.panel(
            workspaceID: workspace.id,
            panelID: panelID
        )
        #expect(index.key(for: panelSource) == panelDirectory)

        workspace.currentDirectory = "/workspace-moved"
        index.replaceContribution(
            source: .workspace(workspace.id),
            key: cacheKey(for: workspace.configurationTrackingDirectory(panelID: nil))
        )

        #expect(index.key(for: panelSource) == panelDirectory)
        #expect(index.key(for: .workspace(workspace.id)) == "/workspace-moved")
    }

    @Test
    func browserWithoutExplicitDirectoryUsesOnlyWorkspaceContribution() throws {
        let workspace = Workspace(
            workingDirectory: "/workspace",
            initialSurface: .browser
        )
        let browserPanelID = try #require(workspace.panels.keys.first)
        #expect(workspace.configurationTrackingDirectory(panelID: browserPanelID) == "/workspace")
        #expect(
            workspace.configurationTrackingPanelContributionDirectory(panelID: browserPanelID) == nil
        )

        var index = CmuxConfigActionCatalogDirectoryIndex(globalKey: globalKey)
        reconcile(workspace, into: &index)
        #expect(index.key(for: .workspace(workspace.id)) == "/workspace")
        #expect(index.key(for: .panel(workspaceID: workspace.id, panelID: browserPanelID)) == nil)
        #expect(index.activeKeys == [globalKey, "/workspace"])
    }

    @Test
    func structuralReconcileHandlesPanelMembershipAndRemoteProvenance() throws {
        let workspace = Workspace(workingDirectory: "/first")
        let firstPanelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: firstPanelID))
        var index = CmuxConfigActionCatalogDirectoryIndex(globalKey: globalKey)
        reconcile(workspace, into: &index)

        let secondPanel = try #require(workspace.newTerminalSurface(
            inPane: paneID,
            focus: false,
            workingDirectory: "/second"
        ))
        reconcile(workspace, into: &index)
        let secondSource = CmuxConfigActionCatalogDirectorySource.panel(
            workspaceID: workspace.id,
            panelID: secondPanel.id
        )
        #expect(index.key(for: secondSource) == "/second")

        workspace.panels.removeValue(forKey: secondPanel.id)
        let removal = reconcile(workspace, into: &index)
        #expect(removal.inactiveKeys == ["/second"])
        #expect(index.key(for: secondSource) == nil)

        workspace.isRemoteTmuxMirror = true
        let remote = reconcile(workspace, into: &index)
        #expect(remote.inactiveKeys.contains("/first"))
        #expect(index.activeKeys == [globalKey])

        workspace.isRemoteTmuxMirror = false
        reconcile(workspace, into: &index)
        #expect(index.key(for: .workspace(workspace.id)) == "/first")
        #expect(index.key(for: .panel(workspaceID: workspace.id, panelID: firstPanelID)) == "/first")
    }

    @Test
    func focusedPanelUpdateEmitsPanelThenWorkspaceEvents() async throws {
        let workspace = Workspace(workingDirectory: "/old")
        let panelID = try #require(workspace.focusedPanelId)
        var index = CmuxConfigActionCatalogDirectoryIndex(globalKey: globalKey)
        reconcile(workspace, into: &index)
        let eventTask = Task { @MainActor in
            var iterator = workspace.configTrackingEvents.makeAsyncIterator()
            var events: [WorkspaceConfigTrackingEvent] = []
            for _ in 0..<2 {
                if let event = await iterator.next() {
                    events.append(event)
                }
            }
            return events
        }
        await Task.yield()

        #expect(workspace.updatePanelDirectory(panelId: panelID, directory: "/new"))
        let events = await eventTask.value
        #expect(events == [.panelDirectoryChanged(panelID), .workspaceDirectoryChanged])

        for event in events {
            apply(event, from: workspace, to: &index)
        }
        #expect(index.referenceCount(for: "/old") == 0)
        #expect(index.referenceCount(for: "/new") == 2)
        #expect(index.key(for: .workspace(workspace.id)) == "/new")
        #expect(index.key(for: .panel(workspaceID: workspace.id, panelID: panelID)) == "/new")
    }

    @Test
    func eventBufferOverflowFallsBackToStructuralReconcile() async {
        let channel = WorkspaceConfigTrackingEventChannel(bufferCapacity: 1)
        channel.send(.workspaceDirectoryChanged)
        channel.send(.panelDirectoryChanged(UUID()))

        var iterator = channel.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event == .structuralChanged)
    }

    @discardableResult
    private func reconcile(
        _ workspace: Workspace,
        into index: inout CmuxConfigActionCatalogDirectoryIndex
    ) -> CmuxConfigActionCatalogDirectoryIndexMutation {
        var panelKeys: [UUID: String] = [:]
        for panelID in workspace.panels.keys {
            if let key = cacheKey(
                for: workspace.configurationTrackingPanelContributionDirectory(panelID: panelID)
            ) {
                panelKeys[panelID] = key
            }
        }
        return index.replaceWorkspace(
            workspaceID: workspace.id,
            workspaceKey: cacheKey(for: workspace.configurationTrackingDirectory(panelID: nil)),
            panelKeys: panelKeys
        )
    }

    private func apply(
        _ event: WorkspaceConfigTrackingEvent,
        from workspace: Workspace,
        to index: inout CmuxConfigActionCatalogDirectoryIndex
    ) {
        switch event {
        case .panelDirectoryChanged(let panelID):
            index.replaceContribution(
                source: .panel(workspaceID: workspace.id, panelID: panelID),
                key: cacheKey(
                    for: workspace.configurationTrackingPanelContributionDirectory(panelID: panelID)
                )
            )
        case .workspaceDirectoryChanged:
            index.replaceContribution(
                source: .workspace(workspace.id),
                key: cacheKey(for: workspace.configurationTrackingDirectory(panelID: nil))
            )
        case .structuralChanged:
            reconcile(workspace, into: &index)
        }
    }

    private func cacheKey(for directory: String?) -> String? {
        guard let directory else { return nil }
        return CmuxConfigStore.actionCatalogCacheKey(startingFrom: directory)
    }
}
