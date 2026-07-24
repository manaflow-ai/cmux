import Foundation
import Testing
import CmuxFoundation
import CmuxRemoteSession
import CmuxSettings
import CmuxTerminalCore
@testable import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal font zoom session persistence")
struct TerminalFontZoomSessionPersistenceTests {
    @Test("workspace font-size shortcuts and equalize default stay distinct")
    func workspaceFontSizeShortcutDefaults() {
        #expect(
            KeyboardShortcutSettings.Action.increaseWorkspaceTerminalFontSize.defaultShortcut
                == StoredShortcut(
                    key: "=",
                    command: true,
                    shift: false,
                    option: false,
                    control: true
                )
        )
        #expect(
            KeyboardShortcutSettings.Action.decreaseWorkspaceTerminalFontSize.defaultShortcut
                == StoredShortcut(
                    key: "-",
                    command: true,
                    shift: false,
                    option: false,
                    control: true
                )
        )
        #expect(
            KeyboardShortcutSettings.Action.resetWorkspaceTerminalFontSize.defaultShortcut
                == StoredShortcut(
                    key: "0",
                    command: true,
                    shift: false,
                    option: false,
                    control: true
                )
        )
        #expect(
            KeyboardShortcutSettings.Action.equalizeSplits.defaultShortcut
                == StoredShortcut(
                    key: "=",
                    command: true,
                    shift: true,
                    option: false,
                    control: true
                )
        )
        #expect(
            CmuxSettings.ShortcutAction.increaseWorkspaceTerminalFontSize.defaultStroke
                == CmuxSettings.ShortcutStroke(key: "=", command: true, control: true)
        )
        #expect(
            CmuxSettings.ShortcutAction.decreaseWorkspaceTerminalFontSize.defaultStroke
                == CmuxSettings.ShortcutStroke(key: "-", command: true, control: true)
        )
        #expect(
            CmuxSettings.ShortcutAction.resetWorkspaceTerminalFontSize.defaultStroke
                == CmuxSettings.ShortcutStroke(key: "0", command: true, control: true)
        )
        #expect(
            CmuxSettings.ShortcutAction.equalizeSplits.defaultStroke
                == CmuxSettings.ShortcutStroke(
                    key: "=",
                    command: true,
                    shift: true,
                    control: true
                )
        )
    }

    @Test("workspace font-size reset clears every override and seeds new terminals")
    func workspaceFontSizeResetFansOutAndInherits() throws {
        let workspace = Workspace()
        let firstPanelID = try #require(workspace.focusedPanelId)
        let firstPanel = try #require(workspace.panels[firstPanelID] as? TerminalPanel)
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let secondPanel = try #require(
            workspace.newTerminalSurface(
                inPane: paneID,
                focus: false,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
        )
        let dockPanel = TerminalPanel(
            workspaceId: workspace.id,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        workspace.dockSplit.panels[dockPanel.id] = dockPanel

        let explicitLineages = [
            TerminalFontSizeLineage(basePoints: 8, isExplicitOverride: true),
            TerminalFontSizeLineage(basePoints: 6, isExplicitOverride: true),
            TerminalFontSizeLineage(basePoints: 4, isExplicitOverride: true),
        ]
        let panels = [firstPanel, secondPanel, dockPanel]
        for (panel, lineage) in zip(panels, explicitLineages) {
            panel.surface.recordCurrentFontSizeLineage(lineage)
        }
        workspace.rememberTerminalConfigInheritanceSource(secondPanel)

        let configuredRuntimePoints = Float32(
            GhosttyConfig.load(
                globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
            ).fontSize
        )
        let configuredBasePoints = CmuxSurfaceConfigTemplate.baseFontSize(
            fromRuntimePoints: configuredRuntimePoints,
            percent: GlobalFontMagnification.storedPercent
        )

        #expect(workspace.resetTerminalFontSizes() == 3)
        for panel in panels {
            let lineage = try #require(panel.surface.fontSizeLineageSnapshot())
            #expect(abs(lineage.basePoints - configuredBasePoints) < 0.001)
            #expect(!lineage.isExplicitOverride)
            #expect(panel.surface.sessionFontSizeOverrideBasePoints() == nil)
            #expect(panel.surface.runtimeCreationConfigTemplate().fontSizeLineage == nil)
        }
        #expect(
            TabManager().inheritedTerminalConfigForNewWorkspace(workspace: workspace)?
                .fontSizeLineage == TerminalFontSizeLineage(
                    basePoints: configuredBasePoints,
                    isExplicitOverride: false
                )
        )

        let inheritedPanel = try #require(
            workspace.newTerminalSurface(
                inPane: paneID,
                focus: false,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
        )
        #expect(
            inheritedPanel.surface.fontSizeLineageSnapshot()
                == TerminalFontSizeLineage(
                    basePoints: configuredBasePoints,
                    isExplicitOverride: false
                )
        )
    }

    @Test("restored terminal zoom survives the next session capture")
    func restoredZoomSurvivesRecapture() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let zoomedSnapshot = try snapshotBySettingTerminalFontSize(
            5.5,
            panelID: panelID,
            in: snapshot
        )
        let restoredWorkspace = Workspace()
        let restoredPanelIDs = restoredWorkspace.restoreSessionSnapshot(zoomedSnapshot)
        let restoredPanelID = restoredPanelIDs[panelID] ?? panelID
        let restoredPanel = try #require(
            restoredWorkspace.panels[restoredPanelID] as? TerminalPanel
        )
        let restoredLineage = try #require(
            restoredPanel.surface.fontSizeLineageSnapshot()
        )

        #expect(restoredLineage.basePoints == 5.5)
        #expect(restoredLineage.isExplicitOverride)

        let recapturedSnapshot = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        let recapturedFontSize = try terminalFontSize(
            panelID: restoredPanelID,
            in: recapturedSnapshot
        )

        #expect(recapturedFontSize == 5.5)

        let inheritedConfig = try #require(
            TabManager().inheritedTerminalConfigForNewWorkspace(workspace: restoredWorkspace)
        )
        #expect(inheritedConfig.fontSize == 5.5)
        #expect(inheritedConfig.fontSizeLineage?.isExplicitOverride == true)
    }

    @Test("unzoomed terminal keeps following config across session restore")
    func unzoomedTerminalDoesNotPersistFontSize() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)

        let initialSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        #expect(try optionalTerminalFontSize(panelID: panelID, in: initialSnapshot) == nil)

        let restoredWorkspace = Workspace()
        let restoredPanelIDs = restoredWorkspace.restoreSessionSnapshot(initialSnapshot)
        let restoredPanelID = restoredPanelIDs[panelID] ?? panelID
        let recapturedSnapshot = restoredWorkspace.sessionSnapshot(includeScrollback: false)

        #expect(
            try optionalTerminalFontSize(panelID: restoredPanelID, in: recapturedSnapshot) == nil
        )
    }

    @Test("oversized persisted zoom follows config instead of restoring")
    func oversizedPersistedZoomIsRejected() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let oversizedSnapshot = try snapshotBySettingTerminalFontSize(
            511,
            panelID: panelID,
            in: workspace.sessionSnapshot(includeScrollback: false)
        )

        let restoredWorkspace = Workspace()
        let restoredPanelIDs = restoredWorkspace.restoreSessionSnapshot(oversizedSnapshot)
        let restoredPanelID = restoredPanelIDs[panelID] ?? panelID
        let restoredPanel = try #require(
            restoredWorkspace.panels[restoredPanelID] as? TerminalPanel
        )

        #expect(restoredPanel.surface.fontSizeLineageSnapshot() == nil)
        #expect(
            try optionalTerminalFontSize(
                panelID: restoredPanelID,
                in: restoredWorkspace.sessionSnapshot(includeScrollback: false)
            ) == nil
        )
    }

    @Test("remembered source publishes zoom and reset lineage for new workspaces")
    func rememberedSourceLineageChangesRefreshNewWorkspaceCache() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let sourcePanel = try #require(workspace.panels[panelID] as? TerminalPanel)

        sourcePanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 7, isExplicitOverride: true)
        )

        #expect(
            TabManager().inheritedTerminalConfigForNewWorkspace(workspace: workspace)?
                .fontSizeLineage == TerminalFontSizeLineage(
                    basePoints: 7,
                    isExplicitOverride: true
                )
        )

        sourcePanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 12, isExplicitOverride: false)
        )

        #expect(
            TabManager().inheritedTerminalConfigForNewWorkspace(workspace: workspace)?
                .fontSizeLineage == TerminalFontSizeLineage(
                    basePoints: 12,
                    isExplicitOverride: false
                )
        )
    }

    @Test("workspace font-size adjustment reaches every terminal and seeds new ones")
    func workspaceFontSizeAdjustmentFansOutAndInherits() throws {
        let workspace = Workspace()
        let firstPanelID = try #require(workspace.focusedPanelId)
        let firstPanel = try #require(workspace.panels[firstPanelID] as? TerminalPanel)
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let secondPanel = try #require(
            workspace.newTerminalSurface(
                inPane: paneID,
                focus: false,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
        )
        let dockPanel = TerminalPanel(
            workspaceId: workspace.id,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        workspace.dockSplit.panels[dockPanel.id] = dockPanel

        firstPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 8, isExplicitOverride: true)
        )
        secondPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 6, isExplicitOverride: true)
        )
        dockPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 4, isExplicitOverride: true)
        )
        workspace.rememberTerminalConfigInheritanceSource(secondPanel)

        #expect(workspace.adjustTerminalFontSizes(byRuntimePoints: -1) == 3)
        #expect(firstPanel.surface.fontSizeLineageSnapshot()?.basePoints == 7)
        #expect(secondPanel.surface.fontSizeLineageSnapshot()?.basePoints == 5)
        #expect(dockPanel.surface.fontSizeLineageSnapshot()?.basePoints == 3)
        #expect(
            TabManager().inheritedTerminalConfigForNewWorkspace(workspace: workspace)?
                .fontSizeLineage == TerminalFontSizeLineage(
                    basePoints: 5,
                    isExplicitOverride: true
                )
        )

        // Pane-local creation inherits that pane's adjusted source terminal.
        let inheritedPanel = try #require(
            workspace.newTerminalSurface(
                inPane: paneID,
                focus: false,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
        )
        #expect(
            inheritedPanel.surface.fontSizeLineageSnapshot()
                == TerminalFontSizeLineage(basePoints: 7, isExplicitOverride: true)
        )
    }

    @Test("Dock-only workspace font-size adjustment seeds its first main terminal")
    func dockOnlyWorkspaceFontSizeAdjustmentSeedsFirstMainTerminal() throws {
        let workspace = Workspace()
        let firstPanelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        _ = try #require(
            workspace.newBrowserSurface(
                inPane: paneID,
                url: URL(string: "about:blank"),
                focus: false,
                creationPolicy: .restoration
            )
        )
        #expect(workspace.closePanel(firstPanelID, force: true))

        let dockPanel = TerminalPanel(
            workspaceId: workspace.id,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        dockPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 5, isExplicitOverride: true)
        )
        workspace.dockSplit.panels[dockPanel.id] = dockPanel

        #expect(workspace.adjustTerminalFontSizes(byRuntimePoints: -1) == 1)
        #expect(
            TabManager().inheritedTerminalConfigForNewWorkspace(workspace: workspace)?
                .fontSizeLineage
                == TerminalFontSizeLineage(basePoints: 4, isExplicitOverride: true)
        )

        let inheritedPanel = try #require(
            workspace.newTerminalSurface(
                inPane: paneID,
                focus: false,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
        )
        #expect(
            inheritedPanel.surface.fontSizeLineageSnapshot()
                == TerminalFontSizeLineage(basePoints: 4, isExplicitOverride: true)
        )
    }

    @Test("workspace font-size adjustment reaches remote tmux mirrors and seeds new panes")
    func workspaceFontSizeAdjustmentIncludesRemoteTmuxMirrors() throws {
        let workspace = Workspace()
        let outerPanelID = try #require(workspace.focusedPanelId)
        let outerPanel = try #require(workspace.panels[outerPanelID] as? TerminalPanel)
        outerPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 8, isExplicitOverride: true)
        )
        workspace.rememberTerminalConfigInheritanceSource(outerPanel)

        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"),
            sessionName: "work"
        )
        let initialLayout = RemoteTmuxLayoutNode(
            width: 80,
            height: 24,
            x: 0,
            y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(width: 40, height: 24, x: 0, y: 0, content: .pane(11)),
                RemoteTmuxLayoutNode(width: 39, height: 24, x: 41, y: 0, content: .pane(22)),
            ])
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: outerPanelID,
            connection: connection,
            layout: initialLayout,
            makePanel: { _ in workspace.makeRemoteTmuxPanePanel(onInput: { _ in }) }
        )
        workspace.setRemoteTmuxWindowMirror(mirror, forPanelId: outerPanelID)
        defer {
            workspace.setRemoteTmuxWindowMirror(nil, forPanelId: outerPanelID)
            mirror.teardown()
            workspace.teardownAllPanels()
        }

        let firstMirrorPanel = try #require(mirror.panel(forPane: 11))
        let secondMirrorPanel = try #require(mirror.panel(forPane: 22))
        firstMirrorPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 6, isExplicitOverride: true)
        )
        secondMirrorPanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 4, isExplicitOverride: true)
        )

        #expect(workspace.adjustTerminalFontSizes(byRuntimePoints: -1) == 3)
        #expect(outerPanel.surface.fontSizeLineageSnapshot()?.basePoints == 7)
        #expect(firstMirrorPanel.surface.fontSizeLineageSnapshot()?.basePoints == 5)
        #expect(secondMirrorPanel.surface.fontSizeLineageSnapshot()?.basePoints == 3)

        mirror.reconcile(
            layout: RemoteTmuxLayoutNode(
                width: 80,
                height: 24,
                x: 0,
                y: 0,
                content: .horizontal([
                    RemoteTmuxLayoutNode(width: 26, height: 24, x: 0, y: 0, content: .pane(11)),
                    RemoteTmuxLayoutNode(width: 26, height: 24, x: 27, y: 0, content: .pane(22)),
                    RemoteTmuxLayoutNode(width: 26, height: 24, x: 54, y: 0, content: .pane(33)),
                ])
            )
        )
        let newMirrorPanel = try #require(mirror.panel(forPane: 33))
        #expect(
            newMirrorPanel.surface.fontSizeLineageSnapshot()
                == TerminalFontSizeLineage(basePoints: 7, isExplicitOverride: true)
        )
    }

    @Test("temporary mobile fit does not replace remembered durable lineage")
    func rememberedSourceMasksTemporaryMobileFitLineage() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let sourcePanel = try #require(workspace.panels[panelID] as? TerminalPanel)
        let durableLineage = TerminalFontSizeLineage(
            basePoints: 12,
            isExplicitOverride: false
        )
        sourcePanel.surface.recordCurrentFontSizeLineage(durableLineage)
        sourcePanel.surface.mobileViewportFontFitState = MobileViewportFontFitState(
            baseRuntimePointSize: 12,
            fittedRuntimePointSize: 6
        )

        _ = sourcePanel.surface.recordObservedFontSizeLineage(
            runtimePoints: 6,
            isExplicitOverride: true,
            globalFontMagnificationPercent: 100
        )

        #expect(
            TabManager().inheritedTerminalConfigForNewWorkspace(workspace: workspace)?
                .fontSizeLineage == durableLineage
        )
    }

    @Test("removed remembered source cannot publish stale lineage")
    func removedRememberedSourceCannotRefreshNewWorkspaceCache() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let sourcePanel = try #require(workspace.panels[panelID] as? TerminalPanel)
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        _ = try #require(
            workspace.newBrowserSurface(
                inPane: paneID,
                url: URL(string: "about:blank"),
                focus: false,
                creationPolicy: .restoration
            )
        )
        sourcePanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 7, isExplicitOverride: true)
        )
        #expect(workspace.closePanel(panelID, force: true))

        sourcePanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 9, isExplicitOverride: true)
        )

        #expect(TabManager().inheritedTerminalConfigForNewWorkspace(workspace: workspace) == nil)
    }

    @Test("cleared zoom follows current config when the runtime is recreated")
    func clearedZoomDoesNotSeedRuntimeRecreation() {
        var restoredTemplate = CmuxSurfaceConfigTemplate()
        restoredTemplate.setFontSize(5.5, isExplicitOverride: true)
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: restoredTemplate,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        surface.surface = UnsafeMutableRawPointer(bitPattern: 0x7540)
        surface.surface = nil

        let resetLineage = TerminalFontSizeLineage(
            basePoints: 12,
            isExplicitOverride: false
        )
        surface.recordCurrentFontSizeLineage(resetLineage)

        #expect(surface.runtimeSurfaceGeneration == 2)
        #expect(surface.fontSizeLineageSnapshot() == resetLineage)
        #expect(surface.runtimeCreationConfigTemplate().fontSizeLineage == nil)
    }

    @Test("initial non-explicit template preserves its font size for first runtime creation")
    func initialNonExplicitTemplateSeedsFirstRuntimeCreation() {
        var inheritedTemplate = CmuxSurfaceConfigTemplate()
        inheritedTemplate.setFontSize(12, isExplicitOverride: false)
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedTemplate,
            runtimeSpawnPolicy: .pacedSessionRestore
        )

        #expect(surface.runtimeSurfaceGeneration == 0)
        #expect(surface.fontSizeLineageSnapshot() == inheritedTemplate.fontSizeLineage)
        #expect(
            surface.runtimeCreationConfigTemplate().fontSizeLineage
                == inheritedTemplate.fontSizeLineage
        )
    }

    @Test("mobile viewport fitting does not claim durable zoom ownership")
    func mobileViewportFitPreservesDurableOwnership() {
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        let configLineage = TerminalFontSizeLineage(
            basePoints: 12,
            isExplicitOverride: false
        )
        surface.recordCurrentFontSizeLineage(configLineage)
        surface.mobileViewportFontFitState = MobileViewportFontFitState(
            baseRuntimePointSize: 12,
            fittedRuntimePointSize: 6
        )

        let fittedLineage = surface.recordObservedFontSizeLineage(
            runtimePoints: 6,
            isExplicitOverride: true,
            globalFontMagnificationPercent: 100
        )

        #expect(fittedLineage == configLineage)
        #expect(surface.sessionFontSizeOverrideBasePoints() == nil)

        let resetLineage = surface.recordObservedFontSizeLineage(
            runtimePoints: 6,
            isExplicitOverride: false,
            globalFontMagnificationPercent: 100
        )

        #expect(resetLineage == TerminalFontSizeLineage(basePoints: 6, isExplicitOverride: false))
        #expect(surface.mobileViewportFontFitState?.baseRuntimePointSize == 6)

        let userLineage = surface.recordObservedFontSizeLineage(
            runtimePoints: 7,
            isExplicitOverride: true,
            globalFontMagnificationPercent: 100
        )

        #expect(userLineage == TerminalFontSizeLineage(basePoints: 7, isExplicitOverride: true))
        #expect(surface.mobileViewportFontFitState?.baseRuntimePointSize == 7)
        #expect(surface.sessionFontSizeOverrideBasePoints() == 7)
    }

    @Test("unzoomed session restore clears inherited explicit zoom")
    func unzoomedRestoreDoesNotBorrowNeighborZoom() throws {
        let workspace = Workspace()
        let sourcePanelID = try #require(workspace.focusedPanelId)
        let sourcePanel = try #require(workspace.panels[sourcePanelID] as? TerminalPanel)
        sourcePanel.surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 5.5, isExplicitOverride: true)
        )
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)

        let restoredPanel = try #require(
            workspace.newTerminalSurface(
                inPane: paneID,
                focus: false,
                runtimeSpawnPolicy: .pacedSessionRestore,
                terminalFontSizeCreationPolicy: .sessionRestore(overrideBasePoints: nil)
            )
        )

        #expect(restoredPanel.surface.fontSizeLineageSnapshot() == nil)
        #expect(restoredPanel.surface.sessionFontSizeOverrideBasePoints() == nil)
        #expect(
            workspace.lastRememberedTerminalPanelForConfigInheritance()?.id == restoredPanel.id
        )
        #expect(workspace.closePanel(sourcePanelID, force: true))
        #expect(
            TabManager().inheritedTerminalConfigForNewWorkspace(workspace: workspace) == nil
        )
    }

    @Test("closing the remembered zoom source discards its explicit lineage")
    func closingZoomSourceClearsWorkspaceFallback() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let snapshot = try snapshotBySettingTerminalFontSize(
            5.5,
            panelID: panelID,
            in: workspace.sessionSnapshot(includeScrollback: false)
        )
        let restoredWorkspace = Workspace()
        let restoredPanelIDs = restoredWorkspace.restoreSessionSnapshot(snapshot)
        let restoredPanelID = restoredPanelIDs[panelID] ?? panelID
        let paneID = try #require(restoredWorkspace.bonsplitController.focusedPaneId)
        _ = try #require(
            restoredWorkspace.newBrowserSurface(
                inPane: paneID,
                url: URL(string: "about:blank"),
                focus: false,
                creationPolicy: .restoration
            )
        )

        #expect(
            TabManager().inheritedTerminalConfigForNewWorkspace(
                workspace: restoredWorkspace
            )?.fontSizeLineage?.isExplicitOverride == true
        )
        #expect(restoredWorkspace.closePanel(restoredPanelID, force: true))
        #expect(
            TabManager().inheritedTerminalConfigForNewWorkspace(
                workspace: restoredWorkspace
            ) == nil
        )
    }

    @Test("unmounted terminal cannot replace workspace zoom source")
    func unmountedTerminalDoesNotReplaceWorkspaceZoomSource() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let snapshot = try snapshotBySettingTerminalFontSize(
            5.5,
            panelID: panelID,
            in: workspace.sessionSnapshot(includeScrollback: false)
        )
        let restoredWorkspace = Workspace()
        let restoredPanelIDs = restoredWorkspace.restoreSessionSnapshot(snapshot)
        let restoredPanelID = restoredPanelIDs[panelID] ?? panelID
        #expect(
            restoredWorkspace.lastRememberedTerminalFontSizeLineageForConfigInheritance()?
                .isExplicitOverride == true
        )

        let unmountedPanel = TerminalPanel(
            workspaceId: restoredWorkspace.id,
            configTemplate: nil,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        restoredWorkspace.rememberTerminalConfigInheritanceSource(unmountedPanel)

        #expect(
            restoredWorkspace.lastRememberedTerminalPanelForConfigInheritance()?.id == restoredPanelID
        )
        #expect(
            restoredWorkspace.lastRememberedTerminalFontSizeLineageForConfigInheritance()?
                .isExplicitOverride == true
        )
    }

    private func snapshotBySettingTerminalFontSize(
        _ fontSize: Double,
        panelID: UUID,
        in snapshot: SessionWorkspaceSnapshot
    ) throws -> SessionWorkspaceSnapshot {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        var panels = try #require(object["panels"] as? [[String: Any]])
        let panelIndex = try #require(panels.firstIndex { $0["id"] as? String == panelID.uuidString })
        var terminal = try #require(panels[panelIndex]["terminal"] as? [String: Any])
        terminal["fontSize"] = fontSize
        panels[panelIndex]["terminal"] = terminal
        object["panels"] = panels

        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
    }

    private func terminalFontSize(
        panelID: UUID,
        in snapshot: SessionWorkspaceSnapshot
    ) throws -> Double {
        let fontSize = try optionalTerminalFontSize(panelID: panelID, in: snapshot)
        return try #require(fontSize)
    }

    private func optionalTerminalFontSize(
        panelID: UUID,
        in snapshot: SessionWorkspaceSnapshot
    ) throws -> Double? {
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        let panels = try #require(object["panels"] as? [[String: Any]])
        let panel = try #require(panels.first { $0["id"] as? String == panelID.uuidString })
        let terminal = try #require(panel["terminal"] as? [String: Any])
        return terminal["fontSize"] as? Double
    }
}
