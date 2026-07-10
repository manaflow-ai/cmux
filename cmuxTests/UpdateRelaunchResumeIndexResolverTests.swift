import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct UpdateRelaunchResumeIndexResolverTests {
    @Test
    func completedThenCachedThenColdIndexesAreResolvedInOrder() {
        let indexes = ProcessDetectedResumeIndexes(
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: .empty
        )
        var events: [String] = []

        let completedResolver = UpdateRelaunchResumeIndexResolver(
            cachedIndexes: {
                events.append("completed-cache")
                return indexes
            },
            loadSynchronously: {
                events.append("completed-load")
                return indexes
            }
        )
        let completed = completedResolver.resolve(completedTerminationIndexes: indexes)
        let cachedResolver = UpdateRelaunchResumeIndexResolver(
            cachedIndexes: {
                events.append("cache-hit")
                return indexes
            },
            loadSynchronously: {
                events.append("cached-load")
                return indexes
            }
        )
        let cached = cachedResolver.resolve(completedTerminationIndexes: nil)
        let coldResolver = UpdateRelaunchResumeIndexResolver(
            cachedIndexes: {
                events.append("cache-miss")
                return nil
            },
            loadSynchronously: {
                events.append("cold-load")
                return indexes
            }
        )
        let cold = coldResolver.resolve(completedTerminationIndexes: nil)

        #expect(
            completed.map { _ in true } == true
                && cached.map { _ in true } == true
                && cold.map { _ in true } == nil
                && events == ["cache-hit", "cache-miss"]
        )
    }
}
