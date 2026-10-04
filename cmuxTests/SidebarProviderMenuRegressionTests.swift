import Foundation
import AppKit
import Testing
import CmuxSidebarProviderKit
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebar
import CmuxWorkspaces
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the right-click sidebar-button view switcher.
///
/// v0.64.10 shipped seven built-in sidebar views — Default Workspaces plus the
/// Project Worktrees, Attention Queue, Dev Servers, Last Prompt, Super Compact,
/// and Browser Stack presets — that the sidebar-button context menu let users
/// switch between. #4994 ("Replace sidebar extension kit contract") swept that
/// menu behind the experimental Extensions beta flag and stubbed the built-in
/// providers out, so on a default install (beta off) the menu and every one of
/// its views disappeared (https://github.com/manaflow-ai/cmux/issues/5173).
///
/// These tests pin the two guarantees the regression broke: the built-in views
/// are available regardless of the experimental flag, and a selected view
/// resolves to itself (which is what drives the menu's active-view checkmark).
@MainActor
@Suite(.serialized)
struct SidebarProviderMenuRegressionTests {
    @Test
    func cortexToggleRoundTripAndUnavailableFallback() throws {
        let suite = "cortex-switch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = CmuxExtensionSidebarSelection.self
        selection.setProviderId(selection.defaultProviderId, defaults: defaults)
        #expect(!selection.toggleCortexSidebar(enabledBundleIDs: [], extensionsEnabled: true, defaults: defaults))
        #expect(defaults.string(forKey: selection.defaultsKey) == selection.defaultProviderId)
        #expect(!selection.toggleCortexSidebar(enabledBundleIDs: ["fr.yoyaku.cortex.sessions"], extensionsEnabled: false, defaults: defaults))
        #expect(selection.toggleCortexSidebar(enabledBundleIDs: ["fr.yoyaku.cortex.sessions"], extensionsEnabled: true, defaults: defaults))
        #expect(selection.isCortexActive(defaults: defaults))
        #expect(defaults.string(forKey: selection.selectedExtensionBundleIDDefaultsKey) == "fr.yoyaku.cortex.sessions")
        // Returning to classic still works if the extension disappears.
        #expect(selection.toggleCortexSidebar(enabledBundleIDs: [], extensionsEnabled: false, defaults: defaults))
        #expect(!selection.isCortexActive(defaults: defaults))
    }

    @Test
    func explicitCortexSelectionCanRecoverAfterReturningToClassic() throws {
        let suite = "cortex-explicit-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = CmuxExtensionSidebarSelection.self
        let ids: Set<String> = ["fr.yoyaku.cortex.sessions"]
        #expect(selection.selectCortexSidebar(enabledBundleIDs: ids, extensionsEnabled: true, defaults: defaults))
        #expect(selection.selectCortexSidebar(enabledBundleIDs: ids, extensionsEnabled: true, defaults: defaults))
        #expect(selection.isCortexActive(defaults: defaults))
        selection.setProviderId(selection.defaultProviderId, defaults: defaults)
        #expect(!selection.isCortexActive(defaults: defaults))
        #expect(defaults.string(forKey: selection.selectedExtensionBundleIDDefaultsKey) == ids.first)
        #expect(!selection.selectCortexSidebar(enabledBundleIDs: [], extensionsEnabled: true, defaults: defaults))
        #expect(defaults.string(forKey: selection.defaultsKey) == selection.defaultProviderId)
        #expect(selection.selectCortexSidebar(enabledBundleIDs: ids, extensionsEnabled: true, defaults: defaults))
        #expect(selection.isCortexActive(defaults: defaults))
    }

    @Test
    func dogfoodCortexSelectionIsConfinedToItsMatchingTaggedHost() {
        let selection = CmuxExtensionSidebarSelection.self
        let id = "fr.yoyaku.cortex.sessions.dogfood.cortex-management"
        #expect(selection.isCortexBundle(id, hostBundleID: "com.cmuxterm.app.debug.cortex.management"))
        #expect(!selection.isCortexBundle(id, hostBundleID: "com.cmuxterm.app.debug.other"))
        #expect(!selection.isCortexBundle(id, hostBundleID: "com.cmuxterm.app"))
        #expect(!selection.isCortexBundle(id, hostBundleID: nil))
        #expect(!selection.isCortexBundle("fr.yoyaku.cortex.sessions.dogfood.Cortex-management", hostBundleID: "com.cmuxterm.app.debug.Cortex.management"))
        #expect(!selection.isCortexBundle("fr.yoyaku.cortex.sessions.dogfood.cortex.management", hostBundleID: "com.cmuxterm.app.debug.cortex.management"))
    }

    @Test
    func managementRenameAndImportanceUseNativeOwnershipWithoutChangingSelection() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let first = Workspace()
        let second = Workspace()
        manager.tabs = [first, second]
        manager.selectedTabId = first.id
        let dispatcher = SidebarExtensionManagementCoordinator(tabManager: manager, notificationStore: .shared)
        #expect(dispatcher.perform(.renameWorkspace(workspaceID: second.id, title: "  Renamed Project  "))?.accepted == true)
        #expect(second.title == "Renamed Project")
        #expect(second.customTitle == "Renamed Project")
        #expect(manager.selectedTabId == first.id)
        let panel = try #require(second.focusedPanelId)
        #expect(dispatcher.perform(.renameSurface(workspaceID: second.id, surfaceID: panel, title: "Session Name"))?.accepted == true)
        #expect(second.panelTitle(panelId: panel) == "Session Name")
        #expect(manager.selectedTabId == first.id)
        #expect(dispatcher.perform(.setWorkspaceImportance(workspaceID: second.id, importance: .priority))?.accepted == true)
        #expect(second.importance == .priority)
        #expect(!second.isPinned)
        #expect(dispatcher.perform(.setWorkspaceImportance(workspaceID: second.id, importance: .followUp))?.accepted == true)
        #expect(second.importance == .followUp)
        #expect(dispatcher.perform(.setWorkspaceImportance(workspaceID: second.id, importance: .none))?.accepted == true)
        #expect(second.importance == .none)
        #expect(manager.tabs.map(\.id) == [first.id, second.id])
        #expect(dispatcher.perform(.renameWorkspace(workspaceID: second.id, title: ""))?.accepted == true)
        #expect(second.customTitle == nil)
        #expect(dispatcher.perform(.renameWorkspace(workspaceID: UUID(), title: "Missing"))?.accepted == false)
    }

    @Test
    func modalRenameCancellationAndRemovedTargetsAreRejected() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let workspace = Workspace()
        manager.tabs = [workspace]
        let cancelled = SidebarExtensionManagementCoordinator(tabManager: manager, notificationStore: .shared, requestTitle: { _, _, _ in nil })
        #expect(cancelled.perform(.renameWorkspace(workspaceID: workspace.id, title: nil))?.rejectionReason == .cancelled)
        #expect(workspace.customTitle == nil)
        let disappearing = SidebarExtensionManagementCoordinator(tabManager: manager, notificationStore: .shared, requestTitle: { _, _, _ in
            manager.tabs = []
            return "Too late"
        })
        #expect(disappearing.perform(.renameWorkspace(workspaceID: workspace.id, title: nil))?.accepted == false)
        #expect(workspace.customTitle == nil)
    }

    @Test
    func nativeGroupsRenameCollapseUngroupAndRequireDeletionConfirmation() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let workspace = Workspace()
        let groupID = UUID()
        workspace.groupId = groupID
        manager.tabs = [workspace]
        manager.workspaceGroups = [WorkspaceGroup(id: groupID, name: "Original", isCollapsed: false, isPinned: false, anchorWorkspaceId: workspace.id, customColor: nil, iconSymbol: nil)]
        let dispatcher = SidebarExtensionManagementCoordinator(tabManager: manager, notificationStore: .shared, confirmGroupDeletion: { _, _ in false })
        #expect(dispatcher.perform(.renameWorkspaceGroup(groupID: groupID, title: "Renamed Folder"))?.accepted == true)
        #expect(manager.workspaceGroups.first?.name == "Renamed Folder")
        #expect(dispatcher.perform(.renameWorkspaceGroup(groupID: groupID, title: " "))?.accepted == false)
        #expect(dispatcher.perform(.setWorkspaceGroupCollapsed(groupID: groupID, isCollapsed: true))?.accepted == true)
        #expect(manager.workspaceGroups.first?.isCollapsed == true)
        #expect(dispatcher.perform(.deleteWorkspaceGroup(groupID: groupID))?.rejectionReason == .cancelled)
        #expect(manager.tabs.map(\.id) == [workspace.id])
        #expect(manager.workspaceGroups.count == 1)
        #expect(dispatcher.perform(.ungroupWorkspaceGroup(groupID: groupID))?.accepted == true)
        #expect(workspace.groupId == nil)
        #expect(manager.workspaceGroups.isEmpty)
        #expect(manager.tabs.map(\.id) == [workspace.id])
    }

    @Test
    func nativeRuntimeRequiresPanelOwnershipAndExactProcessBirthWithoutRestamping() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let pid: pid_t = 12345
        let key = "codex.session-id"
        let identity = AgentPIDProcessIdentity(pid: pid, startSeconds: 100, startMicroseconds: 7)
        let model = workspace.sidebarAgentRuntimeObservation
        model.setAgentPIDs([key: pid])
        model.setAgentPIDProcessIdentitiesByKey([key: identity])
        model.setAgentPIDPanelIdsByKey([key: panelID])
        model.setAgentPIDKeysByPanelId([panelID: [key]])
        let projector = SidebarExtensionRuntimeProjector(processIdentity: { _ in identity })
        #expect(projector.observation(workspace: workspace, panelID: panelID)?.lifecycle == .unknown)
        #expect(projector.observation(workspace: workspace, panelID: panelID)?.observedAt == nil)
        #expect(projector.observation(workspace: workspace, panelID: UUID()) == nil)
        let evidenceDate = Date(timeIntervalSince1970: 110)
        workspace.setAgentLifecycle(key: "codex", panelId: panelID, lifecycle: .running, observedAt: evidenceDate)
        workspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "Arbitrary localized text", timestamp: evidenceDate)
        let observation = try #require(projector.observation(workspace: workspace, panelID: panelID))
        #expect(observation.lifecycle == .running)
        #expect(observation.provenance == .nativeLifecycle)
        #expect(observation.observedAt == evidenceDate)
        #expect(observation.processGeneration == 100_000_007)
        #expect(observation.sessionID == "session-id")
        #expect(projector.observation(workspace: workspace, panelID: panelID) == observation)
        // A second same-tool pane must not overwrite this panel's evidence.
        model.setAgentPIDPanelIdsByKey([key: panelID, "codex.other-session": UUID()])
        workspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "Another pane", timestamp: Date(timeIntervalSince1970: 130))
        #expect(projector.observation(workspace: workspace, panelID: panelID) == observation)
        model.setAgentPIDPanelIdsByKey([key: panelID])
        let replacement = AgentPIDProcessIdentity(pid: pid, startSeconds: 200, startMicroseconds: 0)
        let replacedProjector = SidebarExtensionRuntimeProjector(processIdentity: { _ in replacement })
        #expect(replacedProjector.observation(workspace: workspace, panelID: panelID) == nil)
        model.setAgentPIDProcessIdentitiesByKey([key: replacement])
        #expect(replacedProjector.observation(workspace: workspace, panelID: panelID)?.lifecycle == .unknown)
        #expect(replacedProjector.observation(workspace: workspace, panelID: panelID)?.observedAt == nil)
        #expect(replacedProjector.observation(workspace: workspace, panelID: panelID)?.processGeneration == 200_000_000)
    }

    @Test
    func sameToolPanelsKeepIndependentLifecycleEvidenceAcrossProcessReplacement() throws {
        let workspace = Workspace()
        let firstPanel = try #require(workspace.focusedPanelId)
        let secondPanel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false, initialInput: nil)?.id)
        let firstKey = "codex.first"
        let secondKey = "codex.second"
        let first = AgentPIDProcessIdentity(pid: 12345, startSeconds: 100, startMicroseconds: 0)
        let second = AgentPIDProcessIdentity(pid: 12346, startSeconds: 100, startMicroseconds: 1)
        let model = workspace.sidebarAgentRuntimeObservation
        model.setAgentPIDs([firstKey: first.pid, secondKey: second.pid])
        model.setAgentPIDProcessIdentitiesByKey([firstKey: first, secondKey: second])
        model.setAgentPIDPanelIdsByKey([firstKey: firstPanel, secondKey: secondPanel])
        model.setAgentPIDKeysByPanelId([firstPanel: [firstKey], secondPanel: [secondKey]])
        workspace.setAgentLifecycle(key: "codex", panelId: firstPanel, lifecycle: .running, observedAt: Date(timeIntervalSince1970: 110))
        workspace.setAgentLifecycle(key: "codex", panelId: secondPanel, lifecycle: .needsInput, observedAt: Date(timeIntervalSince1970: 120))
        let projector = SidebarExtensionRuntimeProjector(processIdentity: { $0 == first.pid ? first : second })
        #expect(projector.observation(workspace: workspace, panelID: firstPanel)?.lifecycle == .running)
        #expect(projector.observation(workspace: workspace, panelID: firstPanel)?.observedAt == Date(timeIntervalSince1970: 110))
        #expect(projector.observation(workspace: workspace, panelID: secondPanel)?.lifecycle == .needsInput)
        #expect(projector.observation(workspace: workspace, panelID: secondPanel)?.observedAt == Date(timeIntervalSince1970: 120))
        let replacement = AgentPIDProcessIdentity(pid: second.pid, startSeconds: 200, startMicroseconds: 0)
        model.setAgentPIDProcessIdentitiesByKey([firstKey: first, secondKey: replacement])
        let replaced = SidebarExtensionRuntimeProjector(processIdentity: { $0 == first.pid ? first : replacement })
        #expect(replaced.observation(workspace: workspace, panelID: firstPanel)?.lifecycle == .running)
        #expect(replaced.observation(workspace: workspace, panelID: secondPanel)?.lifecycle == .unknown)
        #expect(replaced.observation(workspace: workspace, panelID: secondPanel)?.observedAt == nil)
        workspace.setAgentLifecycle(key: "codex", panelId: secondPanel, lifecycle: .idle, observedAt: Date(timeIntervalSince1970: 210))
        #expect(replaced.observation(workspace: workspace, panelID: secondPanel)?.lifecycle == .idle)
        #expect(replaced.observation(workspace: workspace, panelID: secondPanel)?.observedAt == Date(timeIntervalSince1970: 210))
        workspace.clearAgentLifecycle(key: "codex", panelId: secondPanel)
        #expect(replaced.observation(workspace: workspace, panelID: secondPanel)?.lifecycle == .unknown)
    }

    @Test
    func nativeErrorGlyphRequiresVerifiedNeedsInputLifecycle() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let identity = AgentPIDProcessIdentity(pid: 12345, startSeconds: 100, startMicroseconds: 0)
        let model = workspace.sidebarAgentRuntimeObservation
        model.setAgentPIDs(["codex": identity.pid])
        model.setAgentPIDProcessIdentitiesByKey(["codex": identity])
        model.setAgentPIDPanelIdsByKey(["codex": panelID])
        workspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "Not parsed", icon: "exclamationmark.triangle.fill", timestamp: Date(timeIntervalSince1970: 110))
        let projector = SidebarExtensionRuntimeProjector(processIdentity: { _ in identity })
        #expect(projector.observation(workspace: workspace, panelID: panelID)?.lifecycle == .unknown)
        workspace.setAgentLifecycle(key: "codex", panelId: panelID, lifecycle: .needsInput, observedAt: Date(timeIntervalSince1970: 111))
        #expect(projector.observation(workspace: workspace, panelID: panelID)?.lifecycle == .error)
        workspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "Error wording must not decide", icon: "bubble.left", timestamp: Date(timeIntervalSince1970: 110))
        workspace.setAgentLifecycle(key: "codex", panelId: panelID, lifecycle: .needsInput, observedAt: Date(timeIntervalSince1970: 112))
        #expect(projector.observation(workspace: workspace, panelID: panelID)?.lifecycle == .needsInput)
        workspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "Old error", icon: "exclamationmark.triangle.fill", timestamp: Date(timeIntervalSince1970: 90))
        workspace.setAgentLifecycle(key: "codex", panelId: panelID, lifecycle: .needsInput, observedAt: Date(timeIntervalSince1970: 113))
        #expect(projector.observation(workspace: workspace, panelID: panelID)?.lifecycle == .needsInput)
    }

    @Test
    func newManagementSnapshotFieldsAdvanceAuthoritativeSequence() {
        let cache = CMUXSidebarSnapshotCache()
        let id = UUID()
        let panelID = UUID()
        let groupID = UUID()
        var snapshot = CmuxSidebarSnapshot(sequence: 4, selectedWorkspaceID: nil, workspaces: [CmuxSidebarWorkspace(id: id, title: "Before", surfaces: [CmuxSidebarSurface(id: panelID, title: "Before tab", kind: .terminal)])])
        #expect(cache.replace(with: snapshot).sequence == 4)
        snapshot.workspaces[0].title = "After"
        #expect(cache.replace(with: snapshot).sequence == 5)
        snapshot.workspaces[0].surfaces[0].title = "After tab"
        #expect(cache.replace(with: snapshot).sequence == 6)
        snapshot.workspaces[0].importance = .priority
        #expect(cache.replace(with: snapshot).sequence == 7)
        snapshot.workspaceGroups = [CmuxSidebarWorkspaceGroup(id: groupID, name: "Empty retained group")]
        #expect(cache.replace(with: snapshot).sequence == 8)
        snapshot.workspaceGroups[0].isCollapsed = true
        #expect(cache.replace(with: snapshot).sequence == 9)
        #expect(cache.replace(with: snapshot).sequence == 9)
        snapshot.workspaces[0].surfaces[0].runtime = CmuxSidebarRuntimeObservation(lifecycle: .needsInput, observedAt: Date(timeIntervalSince1970: 100), provenance: .nativeLifecycle, processGeneration: 1)
        #expect(cache.replace(with: snapshot).sequence == 10)
    }

    @Test
    func importanceAndPanelCustomTitlePublishImmediatelyThroughSharedObservation() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        var count = 0
        let subscription = workspace.sidebarImmediateObservationPublisher.sink { count += 1 }
        defer { subscription.cancel() }
        count = 0
        workspace.importance = .priority
        #expect(count == 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        count = 0
        workspace.setPanelCustomTitle(panelId: panelID, title: "External rename")
        #expect(count == 1)
        #expect(workspace.panelTitle(panelId: panelID) == "External rename")
    }

    /// Stable ids of the seven built-in sidebar views, in menu order.
    private static let builtInViewIDs: [String] = [
        "cmux.sidebar.default",
        "com.example.cmux.sidebar.project-worktrees",
        "com.example.cmux.sidebar.attention-queue",
        "com.example.cmux.sidebar.dev-servers",
        "com.example.cmux.sidebar.last-prompt",
        "com.example.cmux.sidebar.super-compact",
        "com.example.cmux.sidebar.browser-stack",
    ]

    private static let extensionsBetaKey = "extensions.beta.enabled"

    private func withExtensionsBeta(_ enabled: Bool, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Self.extensionsBetaKey)
        defaults.set(enabled, forKey: Self.extensionsBetaKey)
        defer { restore(previous, forKey: Self.extensionsBetaKey) }
        body()
    }

    private func withSelectedProvider(_ providerId: String, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let key = CmuxExtensionSidebarSelection.defaultsKey
        let previous = defaults.object(forKey: key)
        defaults.set(providerId, forKey: key)
        defer { restore(previous, forKey: key) }
        body()
    }

    private func restore(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// The built-in views must remain selectable even when the experimental
    /// Extensions beta is disabled — the regression hid every one of them.
    @Test
    func builtInViewsAvailableWhenExtensionsBetaDisabled() {
        withExtensionsBeta(false) {
            let availableIDs = Set(CmuxExtensionSidebarSelection.descriptors.map(\.id))
            for builtInID in Self.builtInViewIDs {
                #expect(
                    availableIDs.contains(builtInID),
                    "Built-in sidebar view \(builtInID) is missing from the switcher menu"
                )
            }
        }
    }

    /// Persisting a built-in view as the selection drives the menu's active-view
    /// checkmark to that view. This exercises the same path `showMenu` uses to
    /// decide which item is checked — read the persisted id from `UserDefaults`,
    /// resolve it through `effectiveProviderId`, then look up the descriptor —
    /// rather than asserting on the id in isolation.
    @Test
    func persistedBuiltInSelectionDrivesMenuCheckmark() {
        withExtensionsBeta(false) {
            for builtInID in Self.builtInViewIDs {
                withSelectedProvider(builtInID) {
                    let persisted = UserDefaults.standard.string(forKey: CmuxExtensionSidebarSelection.defaultsKey)
                        ?? CmuxExtensionSidebarSelection.defaultProviderId
                    let effective = CmuxExtensionSidebarSelection.effectiveProviderId(
                        persisted,
                        extensionsEnabled: CmuxExtensionSidebarSelection.isEnabled
                    )
                    let checkedID = CmuxExtensionSidebarSelection.descriptor(for: effective).id
                    #expect(
                        checkedID == builtInID,
                        "Persisted selection \(builtInID) did not drive the menu checkmark (got \(checkedID))"
                    )
                }
            }
        }
    }

    /// The hosted-extensions provider belongs to the experimental Extensions
    /// feature, so the effective selection (which the menu checkmark tracks)
    /// downgrades it to the default sidebar while the beta is off and honors it
    /// while the beta is on. Built-in views resolve to themselves either way —
    /// they are never gated by the flag.
    @Test
    func effectiveSelectionGatesHostedExtensionButNotBuiltInViews() {
        let projectWorktrees = "com.example.cmux.sidebar.project-worktrees"
        #expect(
            CmuxExtensionSidebarSelection.effectiveProviderId(projectWorktrees, extensionsEnabled: false) == projectWorktrees
        )
        #expect(
            CmuxExtensionSidebarSelection.effectiveProviderId(projectWorktrees, extensionsEnabled: true) == projectWorktrees
        )

        let hosted = CmuxExtensionSidebarSelection.hostedExtensionsProviderId
        #expect(
            CmuxExtensionSidebarSelection.effectiveProviderId(hosted, extensionsEnabled: true) == hosted
        )
        #expect(
            CmuxExtensionSidebarSelection.effectiveProviderId(hosted, extensionsEnabled: false) == CmuxExtensionSidebarSelection.defaultProviderId
        )
    }

    /// The host renders the selected view through an
    /// `any CmuxSidebarProvider` existential
    /// (`CmuxExtensionSidebarSelection.provider(for:)?.render(snapshot:)`).
    /// `render(snapshot:)` must dynamic-dispatch to the concrete view; if it
    /// instead hits the empty protocol-extension default, every built-in view
    /// renders an empty sidebar even though the provider and workspaces are
    /// present — the second half of #5173. Super Compact lists every workspace
    /// in one section, so its rows must equal the workspace count.
    @Test
    func builtInProviderRendersRowsThroughHostExistential() {
        let snapshot = Self.populatedSnapshot(workspaceCount: 3)
        let provider = CmuxExtensionSidebarSelection.provider(for: "com.example.cmux.sidebar.super-compact")
        #expect(provider != nil, "Super Compact provider should be registered")
        let model = provider?.render(snapshot: snapshot)
        #expect(
            (model?.sections.flatMap(\.rows).count ?? 0) == 3,
            "Selected view rendered no rows through the host existential (empty-sidebar regression)"
        )
    }

    /// `VerticalTabsSidebar.body` decides whether to show the default workspaces
    /// sidebar or an extension sidebar on every render. It used to do that with
    /// `descriptor(for:).id == defaultWorkspacesID`, which rebuilds the full
    /// `descriptors` list — constructing a `SettingCatalog` twice and scanning
    /// the custom-sidebars directory — on every body pass. That per-pass cost was
    /// the multiplier behind the sustained ~100% CPU re-render loop in #5970.
    /// `resolvesToDefaultSidebar(effectiveProviderId:)` is the cheap replacement;
    /// these tests pin that it routes identically to the old descriptor lookup
    /// for every effective selection.
    @Test
    func resolvesToDefaultSidebarMatchesDescriptorRoutingForBuiltInViews() {
        for betaEnabled in [false, true] {
            withExtensionsBeta(betaEnabled) {
                for builtInID in Self.builtInViewIDs {
                    let cheap = CmuxExtensionSidebarSelection.resolvesToDefaultSidebar(effectiveProviderId: builtInID)
                    let viaDescriptor = CmuxExtensionSidebarSelection.descriptor(for: builtInID).id
                        == CmuxSidebarProviderDescriptor.defaultWorkspacesID
                    #expect(
                        cheap == viaDescriptor,
                        "Routing mismatch for \(builtInID) (extensionsBeta=\(betaEnabled)): cheap=\(cheap) descriptor=\(viaDescriptor)"
                    )
                }
                // The default view routes to the workspaces sidebar; every bundled
                // preset routes to an extension sidebar.
                #expect(
                    CmuxExtensionSidebarSelection.resolvesToDefaultSidebar(
                        effectiveProviderId: CmuxExtensionSidebarSelection.defaultProviderId
                    )
                )
                for presetID in Self.builtInViewIDs.dropFirst() {
                    #expect(
                        !CmuxExtensionSidebarSelection.resolvesToDefaultSidebar(effectiveProviderId: presetID),
                        "Bundled preset \(presetID) must route to an extension sidebar, not the default"
                    )
                }
            }
        }
    }

    /// The hosted-extensions provider only appears in `effectiveProviderId`'s
    /// output while the Extensions beta is on, and then it must route to an
    /// extension sidebar (not the default). Matches the descriptor lookup.
    @Test
    func resolvesToDefaultSidebarRoutesHostedExtensionToExtensionSidebar() {
        withExtensionsBeta(true) {
            let hosted = CmuxExtensionSidebarSelection.hostedExtensionsProviderId
            #expect(!CmuxExtensionSidebarSelection.resolvesToDefaultSidebar(effectiveProviderId: hosted))
            #expect(
                CmuxExtensionSidebarSelection.resolvesToDefaultSidebar(effectiveProviderId: hosted)
                    == (CmuxExtensionSidebarSelection.descriptor(for: hosted).id
                        == CmuxSidebarProviderDescriptor.defaultWorkspacesID)
            )
        }
    }

    /// An unknown/stale provider id (e.g. a deleted custom sidebar) has no
    /// renderable provider, so routing falls back to the default workspaces
    /// sidebar — exactly as `descriptor(for:)`'s `?? .defaultWorkspaces` did.
    @Test
    func resolvesToDefaultSidebarFallsBackForUnknownProvider() {
        withExtensionsBeta(true) {
            let unknown = "com.example.cmux.sidebar.does-not-exist-\(UUID().uuidString)"
            #expect(CmuxExtensionSidebarSelection.resolvesToDefaultSidebar(effectiveProviderId: unknown))
            #expect(
                CmuxExtensionSidebarSelection.resolvesToDefaultSidebar(effectiveProviderId: unknown)
                    == (CmuxExtensionSidebarSelection.descriptor(for: unknown).id
                        == CmuxSidebarProviderDescriptor.defaultWorkspacesID)
            )

            // A custom-prefixed selection whose backing file does not exist also
            // falls back to the default sidebar.
            let missingCustom = CmuxExtensionSidebarSelection.customSidebarProviderPrefix
                + "missing-\(UUID().uuidString)"
            #expect(CmuxExtensionSidebarSelection.resolvesToDefaultSidebar(effectiveProviderId: missingCustom))
        }
    }

    /// Custom provider ids are persisted strings, so the fast path must keep the
    /// old descriptor enumeration boundary: only files directly inside the
    /// sidebars directory are renderable.
    @Test
    func customSidebarFileURLRejectsPathTraversalProviderIds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-custom-sidebar-test-\(UUID().uuidString)", isDirectory: true)
        let sidebarsDirectory = root.appendingPathComponent("sidebars", isDirectory: true)
        try FileManager.default.createDirectory(at: sidebarsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let validName = "valid-\(UUID().uuidString)"
        let validURL = sidebarsDirectory.appendingPathComponent("\(validName).swift", isDirectory: false)
        try Data().write(to: validURL)
        #expect(
            CmuxExtensionSidebarSelection.customSidebarFileURL(
                forProviderId: CmuxExtensionSidebarSelection.customSidebarProviderPrefix + validName,
                sidebarsDirectory: sidebarsDirectory
            ) == validURL
        )

        let escapedName = "outside-\(UUID().uuidString)"
        let escapedURL = root.appendingPathComponent("\(escapedName).swift", isDirectory: false)
        try Data().write(to: escapedURL)
        #expect(
            CmuxExtensionSidebarSelection.customSidebarFileURL(
                forProviderId: CmuxExtensionSidebarSelection.customSidebarProviderPrefix + "../\(escapedName)",
                sidebarsDirectory: sidebarsDirectory
            ) == nil
        )
    }

    private static func populatedSnapshot(workspaceCount: Int) -> CmuxSidebarProviderSnapshot {
        let workspaces = (0..<workspaceCount).map { index in
            CmuxSidebarProviderWorkspace(
                id: UUID(),
                title: "Workspace \(index)",
                customDescription: nil,
                isPinned: false,
                rootPath: "/tmp/ws\(index)",
                projectRootPath: "/tmp/ws\(index)",
                branchSummary: "main",
                remoteDisplayTarget: nil,
                remoteConnectionState: "disconnected",
                unreadCount: 0,
                latestNotificationText: nil,
                listeningPorts: []
            )
        }
        return CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: workspaces
        )
    }
}
