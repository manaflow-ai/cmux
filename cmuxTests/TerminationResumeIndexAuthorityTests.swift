import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TerminationResumeIndexAuthorityTests {
    @Test
    func pendingAuthorityFailsClosedToCoreSnapshot() {
        let plan = TerminationResumeIndexSavePlan.resolve(.pending)

        #expect(plan.usesCoreSnapshotFallback)
        #expect(plan.surfaceResumeBindingIndex == nil)
    }

    @Test
    func completedAuthorityPreservesResolvedIndexes() {
        let indexes = ProcessDetectedResumeIndexes(
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: .empty
        )

        let plan = TerminationResumeIndexSavePlan.resolve(.completed(indexes))

        #expect(!plan.usesCoreSnapshotFallback)
        #expect(plan.surfaceResumeBindingIndex.map { _ in true } == true)
    }

    @Test
    func completedUnavailableAuthorityFailsClosedToCoreSnapshot() {
        let plan = TerminationResumeIndexSavePlan.resolve(.completed(nil))

        #expect(plan.usesCoreSnapshotFallback)
        #expect(plan.surfaceResumeBindingIndex == nil)
    }
}
