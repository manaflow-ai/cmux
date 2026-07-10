import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TerminationResumeIndexSavePlanCacheTests {
    @Test
    func coreSaveUsesCompletedCacheWithoutStartingARefresh() {
        let cachedIndexes = ProcessDetectedResumeIndexes(
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: .empty
        )
        var cacheReads = 0

        let plan = TerminationResumeIndexSavePlan.resolve(
            .pending,
            cachedResumeIndexes: {
                cacheReads += 1
                return cachedIndexes
            }
        )

        #expect(!plan.usesCoreSnapshotFallback && cacheReads == 1)
    }
}
