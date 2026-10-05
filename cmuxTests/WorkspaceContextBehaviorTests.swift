import Foundation
import Testing
import CmuxRemoteWorkspace
@_spi(CmuxHostTransport) import CmuxExtensionKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceContextBehaviorTests {
    @Test
    func staleRevisionAndUnknownWorkspaceCannotMutateTheNativeOwner() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let workspace = Workspace()
        manager.tabs = [workspace]
        let coordinator = SidebarExtensionWorkspaceContextCoordinator(tabManager: manager)
        let revision = workspace.workspaceContext.context.revision
        #expect(coordinator.perform(.mutateWorkspaceContext(workspaceID: workspace.id, expectedRevision: revision, mutation: .setSummary("Accepted")))?.accepted == true)
        let accepted = workspace.workspaceContext.context
        let stale = coordinator.perform(.mutateWorkspaceContext(workspaceID: workspace.id, expectedRevision: revision, mutation: .setSummary("Stale overwrite")))
        #expect(stale?.accepted == false)
        #expect(stale?.rejectionReason == .revisionConflict)
        #expect(workspace.workspaceContext.context == accepted)
        #expect(coordinator.perform(.mutateWorkspaceContext(workspaceID: UUID(), expectedRevision: accepted.revision, mutation: .setSummary("Wrong identity")))?.accepted == false)
        manager.tabs = []
        #expect(coordinator.perform(.mutateWorkspaceContext(workspaceID: workspace.id, expectedRevision: accepted.revision, mutation: .setSummary("Removed workspace")))?.accepted == false)
        #expect(workspace.workspaceContext.context == accepted)
    }

    @Test
    func automaticAcceptancePreservesManualDimensionsAndRejectedSemanticIDs() throws {
        let model = WorkspaceContextModel()
        let manual = Self.tag("project:manual", dimension: "project", origin: .automatic)
        try model.mutate(expectedRevision: 0, mutation: .setManualTag(manual))
        #expect(model.context.tags.first?.origin == .manual)
        try model.mutate(expectedRevision: 1, mutation: .rejectAutomaticTags(ids: ["topic:rejected"]))
        let proposal = Self.proposal(tags: [Self.tag("project:auto", dimension: "project"), Self.tag("topic:rejected", dimension: "topic"), Self.tag("stack:swift", dimension: "technology")])
        try model.storeProposal(expectedRevision: 2, proposal: proposal)
        let change = try model.prepareProposal(expectedRevision: 3, proposalID: proposal.id, tagIDs: proposal.suggestedTags.map(\.id), acceptTitle: false, acceptSummary: true)
        model.commitProposal(change, previousDisplayTitle: "Project", titleUndo: nil)
        #expect(model.context.tags.map(\.id) == ["project:manual", "stack:swift"])
        #expect(model.context.tags.first?.origin == .manual)
        #expect(model.context.summary == "Analyzed purpose")
        #expect(model.context.rejectedAutomaticTagIDs == ["topic:rejected"])
        #expect(model.context.revision == 4)
    }

    @Test
    func removingAutomaticTagPersistsRejectionUntilExplicitClearAndReacceptance() throws {
        let model = WorkspaceContextModel()
        let proposal = Self.proposal(tags: [Self.tag("topic:printing", dimension: "topic")])
        try model.storeProposal(expectedRevision: 0, proposal: proposal)
        model.commitProposal(try model.prepareProposal(expectedRevision: 1, proposalID: proposal.id, tagIDs: ["topic:printing"], acceptTitle: false, acceptSummary: false), previousDisplayTitle: "Project", titleUndo: nil)
        try model.mutate(expectedRevision: 2, mutation: .removeTag(id: "topic:printing"))
        #expect(model.context.tags.isEmpty)
        #expect(model.context.rejectedAutomaticTagIDs == ["topic:printing"])
        model.commitProposal(try model.prepareProposal(expectedRevision: 3, proposalID: proposal.id, tagIDs: ["topic:printing"], acceptTitle: false, acceptSummary: false), previousDisplayTitle: "Project", titleUndo: nil)
        #expect(model.context.tags.isEmpty)
        try model.mutate(expectedRevision: 4, mutation: .clearAutomaticTagRejections(ids: ["topic:printing"]))
        #expect(model.context.tags.isEmpty)
        model.commitProposal(try model.prepareProposal(expectedRevision: 5, proposalID: proposal.id, tagIDs: ["topic:printing"], acceptTitle: false, acceptSummary: false), previousDisplayTitle: "Project", titleUndo: nil)
        #expect(model.context.tags.map(\.id) == ["topic:printing"])
    }

    @Test
    func manualSelectionReplacesAutomaticDimensionAndCannotBeRemovedByAutomaticRejection() throws {
        let model = WorkspaceContextModel()
        let automatic = Self.proposal(tags: [Self.tag("project:automatic", dimension: "project")])
        try model.storeProposal(expectedRevision: 0, proposal: automatic)
        model.commitProposal(try model.prepareProposal(expectedRevision: 1, proposalID: automatic.id, tagIDs: ["project:automatic"], acceptTitle: false, acceptSummary: false), previousDisplayTitle: "Project", titleUndo: nil)
        try model.mutate(expectedRevision: 2, mutation: .setManualTag(Self.tag("project:chosen", dimension: "project")))
        #expect(model.context.tags.map(\.id) == ["project:chosen"])
        try model.mutate(expectedRevision: 3, mutation: .rejectAutomaticTags(ids: ["project:chosen"]))
        #expect(model.context.tags.first?.origin == .manual)
        #expect(model.context.tags.first?.id == "project:chosen")
    }

    @Test
    func nativeRenameCapturesAliasesAndInvalidatesStaleAnalysisAcceptance() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let workspace = Workspace()
        manager.tabs = [workspace]
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "Former project"))
        let proposal = Self.proposal(tags: [])
        let coordinator = SidebarExtensionWorkspaceContextCoordinator(tabManager: manager)
        #expect(coordinator.perform(.storeWorkspaceContextProposal(workspaceID: workspace.id, expectedRevision: workspace.workspaceContext.context.revision, proposal: proposal))?.accepted == true)
        let staleRevision = workspace.workspaceContext.context.revision
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "Current project"))
        #expect(workspace.workspaceContext.context.aliases.contains("Former project"))
        #expect(!workspace.workspaceContext.context.aliases.contains("Current project"))
        #expect(coordinator.perform(.applyWorkspaceContextProposal(workspaceID: workspace.id, expectedRevision: staleRevision, proposalID: proposal.id, tagIDs: [], acceptTitle: true, acceptSummary: true))?.rejectionReason == .revisionConflict)
        #expect(workspace.title == "Current project")
    }

    @Test
    func applyingProposalAndUndoRestoreMetadataAndNativeNameWithMonotonicRevision() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let selected = Workspace()
        let workspace = Workspace()
        manager.tabs = [selected, workspace]
        manager.selectedTabId = selected.id
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "Original project"))
        let coordinator = SidebarExtensionWorkspaceContextCoordinator(tabManager: manager)
        let proposal = Self.proposal(tags: [Self.tag("topic:printing", dimension: "topic")])
        var revision = workspace.workspaceContext.context.revision
        #expect(coordinator.perform(.storeWorkspaceContextProposal(workspaceID: workspace.id, expectedRevision: revision, proposal: proposal))?.accepted == true)
        revision = workspace.workspaceContext.context.revision
        let previous = workspace.workspaceContext.context
        #expect(coordinator.perform(.applyWorkspaceContextProposal(workspaceID: workspace.id, expectedRevision: revision, proposalID: proposal.id, tagIDs: ["topic:printing"], acceptTitle: true, acceptSummary: true))?.accepted == true)
        #expect(workspace.title == "Analyzed project")
        #expect(workspace.workspaceContext.context.summary == "Analyzed purpose")
        #expect(workspace.workspaceContext.context.aliases.contains("Original project"))
        #expect(workspace.workspaceContext.context.revision == revision + 1)
        #expect(workspace.workspaceContext.context.canUndo)
        #expect(manager.selectedTabId == selected.id)
        #expect(coordinator.perform(.undoWorkspaceContext(workspaceID: workspace.id, expectedRevision: revision + 1))?.accepted == true)
        #expect(workspace.title == "Original project")
        #expect(workspace.workspaceContext.context.tags == previous.tags)
        #expect(workspace.workspaceContext.context.summary == previous.summary)
        #expect(workspace.workspaceContext.context.analyzedProposal == proposal)
        #expect(workspace.workspaceContext.context.revision == revision + 2)
        #expect(!workspace.workspaceContext.context.canUndo)
        #expect(coordinator.perform(.undoWorkspaceContext(workspaceID: workspace.id, expectedRevision: revision + 2))?.accepted == false)
    }

    @Test
    func laterManualRenameCannotBeOverwrittenByOldUndo() throws {
        let model = WorkspaceContextModel()
        try model.mutate(expectedRevision: 0, mutation: .setSummary("Purpose"))
        #expect(model.context.canUndo)
        model.recordRename(from: "Old", to: "User choice")
        #expect(!model.context.canUndo)
        #expect(throws: WorkspaceContextModel.MutationError.undoUnavailable) { try model.pendingUndo(expectedRevision: 2) }
        #expect(model.context.aliases == ["Old"])
    }

    @Test
    func workspaceSessionPersistenceRetainsAcceptedContextAnalysisRejectionsAndUndo() throws {
        let workspace = Workspace()
        workspace.setCustomTitle("Former project")
        workspace.setCustomTitle("Current project")
        let model = workspace.workspaceContext
        try model.mutate(expectedRevision: model.context.revision, mutation: .setManualTag(Self.tag("topic:manual", dimension: "topic")))
        try model.mutate(expectedRevision: model.context.revision, mutation: .rejectAutomaticTags(ids: ["topic:rejected"]))
        let proposal = Self.proposal(tags: [Self.tag("technology:swift", dimension: "technology")])
        try model.storeProposal(expectedRevision: model.context.revision, proposal: proposal)
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        let restored = Workspace()
        restored.restoreSessionSnapshot(decoded)
        #expect(restored.workspaceContext.persisted == model.persisted)
        #expect(restored.workspaceContext.context.analyzedProposal?.conversationIDs == ["Exact-Codex-ID", "Exact-Claude-ID"])
        #expect(restored.workspaceContext.context.aliases.contains("Former project"))
        #expect(restored.workspaceContext.context.tags.first?.origin == .manual)
        #expect(restored.title == "Current project")
        var legacy = decoded
        legacy.workspaceContext = nil
        let legacyRestored = Workspace()
        legacyRestored.restoreSessionSnapshot(legacy)
        #expect(legacyRestored.workspaceContext.context == CmuxSidebarWorkspaceContext())
    }

    @Test
    func staleProposalIDInvalidSelectionAndOversizedPayloadDoNotPartiallyMutate() throws {
        let model = WorkspaceContextModel()
        let proposal = Self.proposal(tags: [Self.tag("topic:printing", dimension: "topic")])
        try model.storeProposal(expectedRevision: 0, proposal: proposal)
        let initial = model.persisted
        #expect(throws: WorkspaceContextModel.MutationError.proposalNotFound) {
            try model.prepareProposal(expectedRevision: 1, proposalID: UUID(), tagIDs: [], acceptTitle: false, acceptSummary: true)
        }
        #expect(throws: WorkspaceContextModel.MutationError.invalidPayload) {
            try model.prepareProposal(expectedRevision: 1, proposalID: proposal.id, tagIDs: ["unknown"], acceptTitle: false, acceptSummary: true)
        }
        #expect(throws: WorkspaceContextModel.MutationError.invalidPayload) {
            try model.mutate(expectedRevision: 1, mutation: .setSummary(String(repeating: "x", count: 2_001)))
        }
        #expect(model.persisted == initial)
    }

    @Test
    func metadataOnlyMutationChangesSessionAutosaveFingerprint() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let workspace = Workspace()
        manager.tabs = [workspace]
        let previous = manager.sessionAutosaveFingerprint()
        let revision = workspace.workspaceContext.context.revision
        try workspace.workspaceContext.mutate(expectedRevision: revision, mutation: .setSummary("Persist this without renaming"))
        #expect(manager.sessionAutosaveFingerprint() != previous)
        let saved = manager.sessionAutosaveFingerprint()
        #expect(saved == manager.sessionAutosaveFingerprint())
    }

    @Test
    func projectContextMethodsRemainDeniedByTheRemoteRelay() throws {
        let policy = RemoteRelayCommandPolicy()
        for method in ["workspace.context.get", "workspace.context.mutate", "workspace.context.proposal", "workspace.context.apply", "workspace.context.undo"] {
            let command = try JSONSerialization.data(withJSONObject: ["id": "context-test", "method": method, "params": ["workspace_id": UUID().uuidString]])
            let result = policy.evaluate(commandLine: command, workspaceAliases: [:], surfaceAliases: [:])
            guard case .deny = result else { Issue.record("Project context leaked through remote relay: \(method)"); continue }
        }
    }

    @Test
    func exactProposalRejectionSurvivesPersistenceAndClearsWithExplicitUndo() throws {
        let model = WorkspaceContextModel()
        let proposal = Self.proposal(tags: [])
        try model.storeProposal(expectedRevision: 0, proposal: proposal)
        try model.mutate(expectedRevision: 1, mutation: .rejectProposal(id: proposal.id))
        #expect(model.context.analyzedProposal == nil)
        #expect(model.context.rejectedSourceFingerprints == [proposal.sourceFingerprint])
        let restored = WorkspaceContextModel()
        restored.restore(try JSONDecoder().decode(WorkspaceContextModel.Persisted.self, from: JSONEncoder().encode(model.persisted)))
        #expect(throws: WorkspaceContextModel.MutationError.invalidPayload) { try restored.storeProposal(expectedRevision: 2, proposal: proposal) }
        let undo = try restored.pendingUndo(expectedRevision: 2)
        restored.commitUndo(undo, revision: 2)
        #expect(restored.context.rejectedSourceFingerprints.isEmpty)
        #expect(restored.context.analyzedProposal == proposal)
        #expect(restored.context.revision == 3)
    }

    @Test
    func staleProposalRejectionCannotRejectReplacementMaterial() throws {
        let model = WorkspaceContextModel()
        let proposal = Self.proposal(tags: [])
        try model.storeProposal(expectedRevision: 0, proposal: proposal)
        #expect(throws: WorkspaceContextModel.MutationError.proposalNotFound) { try model.mutate(expectedRevision: 1, mutation: .rejectProposal(id: UUID())) }
        #expect(model.context.analyzedProposal == proposal)
        try model.mutate(expectedRevision: 1, mutation: .rejectProposal(id: proposal.id))
        try model.mutate(expectedRevision: 2, mutation: .clearProposalRejections(fingerprints: [proposal.sourceFingerprint]))
        try model.storeProposal(expectedRevision: 3, proposal: proposal)
        #expect(model.context.analyzedProposal == proposal)
    }

    private static func tag(_ id: String, dimension: String, origin: CmuxSidebarContextTagOrigin = .automatic) -> CmuxSidebarContextTag {
        CmuxSidebarContextTag(id: id, label: id, dimension: dimension, origin: origin, source: "test-analyzer")
    }

    private static func proposal(tags: [CmuxSidebarContextTag]) -> CmuxSidebarWorkspaceContextProposal {
        CmuxSidebarWorkspaceContextProposal(suggestedTags: tags, suggestedTitle: "Analyzed project", summary: "Analyzed purpose", source: "test-analyzer", sourceFingerprint: "sha256:exact-source", conversationIDs: ["Exact-Codex-ID", "Exact-Claude-ID"], analyzedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
