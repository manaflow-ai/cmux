import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DeferredAgentResumeAdmissionOwnerTests {
    @Test("A new restore runs admission while the previous pass waits for unrelated evidence")
    func newRestoreInterruptsEvidenceWait() async throws {
        let owner = DeferredAdmissionTestOwner()
        defer { owner.deferredAgentResumeIndexTask?.cancel() }
        var scans = owner.scans.stream.makeAsyncIterator()
        var waits = owner.waits.stream.makeAsyncIterator()
        let first = UUID()
        owner.deferAgentResumeRestore(panelId: first, restore: restore(first))
        #expect(await scans.next() == [first])
        _ = await waits.next()
        let previousTask = try #require(owner.deferredAgentResumeIndexTask)

        let second = UUID()
        owner.deferAgentResumeRestore(panelId: second, restore: restore(second))
        #expect(await scans.next() == Set([first, second]))
        #expect(previousTask.isCancelled)
        #expect(owner.deferredAgentResumeRestoresByPanelId.count == 2)
    }

    @Test("An evidence wait does not retain a closed container")
    func waitingTaskDoesNotRetainOwner() async {
        let (deinitializations, deinitialization) = AsyncStream<Void>.makeStream()
        var owner: DeferredAdmissionTestOwner? = DeferredAdmissionTestOwner(deinitialization: deinitialization)
        var deinitializationsIterator = deinitializations.makeAsyncIterator()
        var waits = owner!.waits.stream.makeAsyncIterator()
        let panel = UUID()
        owner?.deferAgentResumeRestore(panelId: panel, restore: restore(panel))
        let task = owner?.deferredAgentResumeIndexTask
        defer { task?.cancel() }
        _ = await waits.next()
        owner = nil
        #expect(await deinitializationsIterator.next() != nil)
    }

    private func restore(_ panel: UUID) -> DeferredAgentResumeRestore {
        DeferredAgentResumeRestore(
            stablePanelID: panel, restorableAgent: nil, resumeBinding: nil,
            restoresRemoteWorkspaceTerminalSnapshot: false, workingDirectory: nil, resumeWorkingDirectory: nil
        )
    }
}
