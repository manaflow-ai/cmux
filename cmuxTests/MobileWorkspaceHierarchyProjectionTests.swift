import AppKit
import Combine
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct MobileWorkspaceHierarchyProjectionTests {
    @Test func digestIndexResamplesOnlyTheChangedWorkspace() throws {
        let firstManager = TabManager()
        let secondManager = TabManager()
        let first = try #require(firstManager.selectedWorkspace)
        let second = try #require(secondManager.selectedWorkspace)
        let workspaces = [first, second]
        var sampledWorkspaceIDs: [UUID] = []
        var index = MobileWorkspaceListProjection.DigestIndex()

        _ = index.refresh(tabs: workspaces, resampling: Set(workspaces.map(\.id))) { workspace in
            sampledWorkspaceIDs.append(workspace.id)
            return workspace.id.hashValue
        }
        #expect(sampledWorkspaceIDs == workspaces.map(\.id))

        sampledWorkspaceIDs.removeAll()
        _ = index.refresh(tabs: workspaces, resampling: [second.id]) { workspace in
            sampledWorkspaceIDs.append(workspace.id)
            return workspace.id.hashValue
        }
        #expect(sampledWorkspaceIDs == [second.id])
    }

    @Test func observerDigestIndexScopesSamplingAtOneThousandWorkspaces() {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        var workspaces: [Workspace] = []
        workspaces.reserveCapacity(1_000)
        for index in 0..<1_000 {
            autoreleasepool {
                workspaces.append(Workspace(
                    title: "Scale \(index)",
                    initialSurface: .cloudVMLoading,
                    allowTextBoxFocusDefault: false
                ))
            }
        }
        manager.tabs = workspaces
        manager.selectedTabId = workspaces.first?.id

        var generations: [UUID: Int] = [:]
        var sampleCounts: [UUID: Int] = [:]
        let observer = MobileWorkspaceListObserver(
            tabManager: manager,
            focusEventSequenceService: MobileWorkspaceFocusEventSequenceService(),
            workspaceDigestSampler: { workspace, previewSignature in
                sampleCounts[workspace.id, default: 0] += 1
                var hasher = Hasher()
                hasher.combine(workspace.id)
                hasher.combine(generations[workspace.id] ?? 0)
                hasher.combine(previewSignature)
                return hasher.finalize()
            }
        )
        defer { withExtendedLifetime(observer) {} }

        #expect(sampleCounts.count == 1_000)
        #expect(sampleCounts.values.reduce(0, +) == 1_000)

        let changedWorkspace = workspaces[500]
        generations[changedWorkspace.id] = 1
        sampleCounts.removeAll()
        observer.emitIfNeeded(
            force: false,
            resamplingWorkspaceIDs: [changedWorkspace.id]
        )
        #expect(sampleCounts == [changedWorkspace.id: 1])

        sampleCounts.removeAll()
        manager.selectedTabId = workspaces[750].id
        observer.emitIfNeeded(force: false, resamplingWorkspaceIDs: [])
        #expect(
            sampleCounts.isEmpty,
            "selection and group-only summary changes must reuse cached workspace digests"
        )

        let newcomer = Workspace(
            title: "Scale newcomer",
            initialSurface: .cloudVMLoading,
            allowTextBoxFocusDefault: false
        )
        sampleCounts.removeAll()
        manager.tabs.append(newcomer)
        observer.emitIfNeeded(force: false, resamplingWorkspaceIDs: [])
        #expect(sampleCounts == [newcomer.id: 1])
    }

    @Test func closeConfirmationFallbackIsLazyForKnownShellActivity() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        var evaluations = 0
        let fallback = {
            evaluations += 1
            return false
        }

        workspace.updatePanelShellActivityState(panelId: panelID, state: .promptIdle)
        let promptIdleNeedsConfirmation = workspace.panelNeedsConfirmClose(
            panelId: panelID,
            fallbackNeedsConfirmClose: fallback
        )
        #expect(!promptIdleNeedsConfirmation)
        workspace.updatePanelShellActivityState(panelId: panelID, state: .commandRunning)
        let commandRunningNeedsConfirmation = workspace.panelNeedsConfirmClose(
            panelId: panelID,
            fallbackNeedsConfirmClose: fallback
        )
        #expect(commandRunningNeedsConfirmation)
        #expect(evaluations == 0)

        workspace.updatePanelShellActivityState(panelId: panelID, state: .unknown)
        let unknownNeedsConfirmation = workspace.panelNeedsConfirmClose(
            panelId: panelID,
            fallbackNeedsConfirmClose: fallback
        )
        #expect(!unknownNeedsConfirmation)
        #expect(evaluations == 1)
    }

    @Test func remoteMirrorActivityOverridesLocalCloseConfirmationFallback() {
        var fallbackEvaluations = 0
        let idleMirrorNeedsConfirmation = Workspace.resolveCloseConfirmation(
            remoteMirrorHasActiveCommand: false,
            shellActivityState: .unknown,
            fallbackNeedsConfirmClose: {
                fallbackEvaluations += 1
                return true
            }
        )
        let activeMirrorNeedsConfirmation = Workspace.resolveCloseConfirmation(
            remoteMirrorHasActiveCommand: true,
            shellActivityState: .promptIdle,
            fallbackNeedsConfirmClose: {
                fallbackEvaluations += 1
                return false
            }
        )

        #expect(!idleMirrorNeedsConfirmation)
        #expect(activeMirrorNeedsConfirmation)
        #expect(fallbackEvaluations == 0)
    }

    @Test func mobileRemoteCloseUsesLiveActivityAndFailsClosedWhenItIsUnavailable() {
        #expect(Workspace.resolveMobileRemoteCloseConfirmation(
            cachedHasActiveCommand: false,
            liveHasActiveCommand: true
        ))
        #expect(Workspace.resolveMobileRemoteCloseConfirmation(
            cachedHasActiveCommand: false,
            liveHasActiveCommand: nil
        ))
        #expect(!Workspace.resolveMobileRemoteCloseConfirmation(
            cachedHasActiveCommand: true,
            liveHasActiveCommand: false
        ))
    }

    @Test func observerDigestIgnoresUnpublishedCloseConfirmationFallback() {
        let workspaceID = UUID()
        let terminalID = UUID()
        func digest(requiresCloseConfirmation: Bool) -> Int {
            let list = MobileWorkspaceHierarchyProjection.ListValue(
                schemaVersion: MobileWorkspaceHierarchyProjection.schemaVersion,
                id: workspaceID,
                title: "Workspace",
                isPinned: false,
                groupID: nil,
                previewSignature: nil,
                orderedPanelIDs: [terminalID],
                pinnedPanelIDs: [],
                panes: [],
                terminals: [.init(
                    id: terminalID,
                    title: "Terminal",
                    currentDirectory: nil,
                    paneID: nil,
                    canClose: true,
                    requiresCloseConfirmation: requiresCloseConfirmation,
                    isReady: true
                )],
                surfaces: [],
                currentDirectory: nil,
                panelDirectories: []
            )
            var hasher = Hasher()
            list.hashObserverIdentity(into: &hasher)
            return hasher.finalize()
        }

        #expect(digest(requiresCloseConfirmation: false) == digest(requiresCloseConfirmation: true))
    }

    @Test func fullListProjectionSkipsLiveFallbackAndFailsClosedForUnknownActivity() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        _ = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        let terminalIDs = workspace.orderedPanelIds.filter {
            workspace.terminalPanel(for: $0) != nil
        }
        #expect(terminalIDs.count == 2)
        for terminalID in terminalIDs {
            workspace.updatePanelShellActivityState(panelId: terminalID, state: .unknown)
        }

        var digestFallbackEvaluations = 0
        let digestWithoutConfirmation = MobileWorkspaceListProjection.digest(
            tabs: [workspace],
            groups: [],
            selectedTabID: workspace.id,
            previewSignatures: [:],
            fallbackNeedsConfirmClose: { _, sampledID in
                #expect(terminalIDs.contains(sampledID))
                digestFallbackEvaluations += 1
                return false
            }
        )
        let digestWithConfirmation = MobileWorkspaceListProjection.digest(
            tabs: [workspace],
            groups: [],
            selectedTabID: workspace.id,
            previewSignatures: [:],
            fallbackNeedsConfirmClose: { _, sampledID in
                #expect(terminalIDs.contains(sampledID))
                digestFallbackEvaluations += 1
                return true
            }
        )

        #expect(digestFallbackEvaluations == 0)
        #expect(digestWithoutConfirmation == digestWithConfirmation)

        var payloadFallbackEvaluations = 0
        let payload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: nil,
            fallbackNeedsConfirmClose: { sampledID in
                #expect(terminalIDs.contains(sampledID))
                payloadFallbackEvaluations += 1
                return false
            }
        )
        let terminals = try #require(payload["terminals"] as? [[String: Any]])
        #expect(payloadFallbackEvaluations == 0)
        #expect(terminals.count == 2)
        #expect(terminals.allSatisfy {
            $0["requires_close_confirmation"] as? Bool == true
        })

        var exactCloseFallbackEvaluations = 0
        let exactCloseNeedsConfirmation = workspace.panelNeedsConfirmClose(
            panelId: try #require(terminalIDs.first),
            fallbackNeedsConfirmClose: {
                exactCloseFallbackEvaluations += 1
                return false
            }
        )
        #expect(exactCloseFallbackEvaluations == 1)
        #expect(!exactCloseNeedsConfirmation)
    }

    @Test func directTerminalFocusSampleMatchesFullProjection() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)

        let directFocus = MobileWorkspaceHierarchyProjection.FocusValue(workspace: workspace)
        let fullFocus = MobileWorkspaceHierarchyProjection(workspace: workspace).focus

        #expect(directFocus == fullFocus)
        #expect(directFocus.selectedTerminalID == workspace.focusedTerminalPanel?.id)
    }

    @Test func pinningTerminalInStableOrderChangesProjectionAndCloseability() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalID = try #require(workspace.focusedPanelId)
        _ = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        let orderBefore = workspace.orderedPanelIds
        let hashBefore = MobileWorkspaceListObserver.summaryHash(
            for: [workspace], groups: [],
            selectedTabID: workspace.id, previewSignatures: [:]
        )
        let projectionBefore = MobileWorkspaceListProjection(
            tabs: [workspace], groups: [],
            selectedTabID: workspace.id, previewSignatures: [:]
        )
        let payloadBefore = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: terminalID
        )
        let terminalBefore = try #require((payloadBefore["terminals"] as? [[String: Any]])?.first)
        #expect(terminalBefore["can_close"] as? Bool == true)

        var publisherWakeups = 0
        let cancellable = workspace.$pinnedPanelIds.dropFirst().sink { _ in
            publisherWakeups += 1
        }
        workspace.setPanelPinned(panelId: terminalID, pinned: true)
        withExtendedLifetime(cancellable) {}

        #expect(workspace.orderedPanelIds == orderBefore, "pinning the first tab must preserve its order")
        #expect(publisherWakeups == 1, "the pinned-panel source must wake its observer")
        let hashAfter = MobileWorkspaceListObserver.summaryHash(
            for: [workspace], groups: [],
            selectedTabID: workspace.id, previewSignatures: [:]
        )
        let projectionAfter = MobileWorkspaceListProjection(
            tabs: [workspace], groups: [],
            selectedTabID: workspace.id, previewSignatures: [:]
        )
        #expect(projectionAfter != projectionBefore)
        #expect(projectionAfter.schemaVersion == MobileWorkspaceHierarchyProjection.schemaVersion)
        #expect(hashAfter != hashBefore, "pinning changes terminal closeability and must change the projection")
        let payloadAfter = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: terminalID
        )
        let terminalAfter = try #require((payloadAfter["terminals"] as? [[String: Any]])?.first)
        #expect(terminalAfter["can_close"] as? Bool == false)
    }

    @Test func browserSelectionHasNoProjectedTerminalAndChangesScopedFocusSignature() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let terminalID = try #require(workspace.focusedTerminalPanel?.id)
        let terminalFocus = MobileWorkspaceHierarchyProjection.FocusValue(workspace: workspace)
        var terminalHasher = Hasher()
        terminalHasher.combine(terminalFocus)
        let terminalSignature = terminalHasher.finalize()
        let browser = try #require(workspace.newBrowserSurface(
            inPane: paneID,
            focus: true,
            creationPolicy: .restoration
        ))

        #expect(workspace.focusedPanelId == browser.id)
        #expect(workspace.focusedTerminalPanel == nil)
        let browserProjection = MobileWorkspaceHierarchyProjection(workspace: workspace)
        let directBrowserFocus = MobileWorkspaceHierarchyProjection.FocusValue(workspace: workspace)
        #expect(directBrowserFocus == browserProjection.focus)
        #expect(directBrowserFocus.selectedTerminalID == nil)
        #expect(browserProjection.focus.selectedTerminalID == nil)
        let eventPayload = directBrowserFocus.eventPayload(sequence: 7)
        #expect(eventPayload["selected_terminal_id"] is NSNull)
        #expect(eventPayload["seq"] as? UInt64 == 7)
        var browserHasher = Hasher()
        browserHasher.combine(directBrowserFocus)
        #expect(browserHasher.finalize() != terminalSignature, "browser selection must change the scoped focus value")

        let payload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: nil
        )
        #expect(payload["selected_terminal_id"] is NSNull)
        let terminals = try #require(payload["terminals"] as? [[String: Any]])
        let terminal = try #require(terminals.first(where: { $0["id"] as? String == terminalID.uuidString }))
        #expect(terminal["is_focused"] as? Bool == false)
    }
}
