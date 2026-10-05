import Foundation
import Testing
@_spi(CmuxHostTransport) import CmuxExtensionKit
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarOrganizationCoordinatorTests {
    @Test func allNativeWorkspacesAreIncludedIndependentlyOfSelection() async throws {
        let service = ImmediateAnalysis()
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false, organizationService: service)
        let first = Workspace(), second = Workspace()
        manager.tabs = [first, second, first]
        manager.selectedTabId = second.id
        let result = await manager.sidebarOrganizationCoordinator.analyze(tabManager: manager)
        #expect(result.accepted)
        #expect(await service.ids == [first.id.uuidString, second.id.uuidString])
        #expect(manager.selectedTabId == second.id)
        #expect(first.workspaceContext.context.analyzedProposal != nil)
        #expect(second.workspaceContext.context.analyzedProposal != nil)
        #expect(first.workspaceContext.context.summary == nil)
        #expect(first.title != "Suggested title")
    }

    @Test func renameDuringAnalysisRefusesTheEntireBatch() async {
        let service = HeldAnalysis()
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false, organizationService: service)
        let first = Workspace(), second = Workspace()
        manager.tabs = [first, second]
        let task = Task { await manager.sidebarOrganizationCoordinator.analyze(tabManager: manager) }
        while !(await service.hasStarted) { await Task.yield() }
        _ = manager.setCustomTitle(tabId: second.id, title: "User choice")
        await service.finish()
        let result = await task.value
        #expect(!result.accepted)
        #expect(result.rejectionReason == .revisionConflict)
        #expect(first.workspaceContext.context.analyzedProposal == nil)
        #expect(second.title == "User choice")
    }

    @Test func cancelledAnalysisCannotMutateNativeState() async {
        let service = HeldAnalysis()
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false, organizationService: service)
        let workspace = Workspace(); manager.tabs = [workspace]
        let task = Task { await manager.sidebarOrganizationCoordinator.analyze(tabManager: manager) }
        while !(await service.hasStarted) { await Task.yield() }
        task.cancel(); await service.finish()
        #expect(!(await task.value).accepted)
        #expect(workspace.workspaceContext.context.analyzedProposal == nil)
    }

    @Test func importCannotSilentlyWidenAnExplicitWorkspaceSelection() async throws {
        let service = ImmediateAnalysis()
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false, organizationService: service)
        let first = Workspace(), second = Workspace(); manager.tabs = [first, second]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(SidebarOrganizationInput.self,
            from: await manager.sidebarOrganizationCoordinator.export(tabManager: manager))
        let result = await manager.sidebarOrganizationCoordinator.analyze(tabManager: manager,
            workspaceIDs: [first.id], exportID: exported.id, review: Data())
        #expect(!result.accepted)
        #expect(await service.ids.isEmpty)
        #expect(first.workspaceContext.context.analyzedProposal == nil)
        #expect(second.workspaceContext.context.analyzedProposal == nil)
    }

    @Test func expiredExportCannotApplyReview() async throws {
        let service = ImmediateAnalysis()
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false, organizationService: service)
        manager.tabs = [Workspace()]
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = SidebarOrganizationCoordinator(service: service, now: { now })
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(SidebarOrganizationInput.self, from: await coordinator.export(tabManager: manager))
        now = now.addingTimeInterval(601)
        let result = await coordinator.analyze(tabManager: manager, exportID: exported.id, review: Data())
        #expect(result.rejectionReason == .revisionConflict)
        #expect(manager.tabs.first?.workspaceContext.context.analyzedProposal == nil)
    }

    nonisolated private static func output(_ input: SidebarOrganizationInput) -> SidebarOrganizationOutput {
        .init(schemaVersion: 1, proposals: input.workspaces.map { workspace in
            .init(workspaceId: workspace.id, expectedRevision: workspace.revision, id: UUID(), suggestedTags: [],
                suggestedTitle: "Suggested title", summary: "Suggested purpose", source: "fixture",
                sourceFingerprint: "sha256:" + workspace.id, conversationIDs: [], analyzedAt: input.createdAt, evidence: [])
        }, diagnostics: [])
    }
    private actor ImmediateAnalysis: SidebarOrganizationAnalyzing {
        private(set) var ids: [String] = []
        func analyze(_ input: SidebarOrganizationInput, review: Data?) async throws -> SidebarOrganizationOutput {
            ids = input.workspaces.map(\.id)
            return SidebarOrganizationCoordinatorTests.output(input)
        }
    }
    private actor HeldAnalysis: SidebarOrganizationAnalyzing {
        private var input: SidebarOrganizationInput?
        private var continuation: CheckedContinuation<SidebarOrganizationOutput, Never>?
        var hasStarted: Bool { continuation != nil }
        func analyze(_ input: SidebarOrganizationInput, review: Data?) async throws -> SidebarOrganizationOutput {
            self.input = input
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish() {
            guard let input, let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: SidebarOrganizationCoordinatorTests.output(input))
        }
    }
}
