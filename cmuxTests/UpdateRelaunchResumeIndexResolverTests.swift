import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct UpdateRelaunchResumeIndexResolverTests {
    @Test
    func completedAuthorityIsUsedWhilePendingAuthorityFailsClosed() {
        let indexes = ProcessDetectedResumeIndexes(
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: .empty
        )
        var events: [String] = []

        let completedResolver = UpdateRelaunchResumeIndexResolver(
            cachedIndexes: {
                events.append("completed-cache")
                return indexes
            }
        )
        let completed = completedResolver.resolve(coordinatedBy: .completed(indexes))
        let unavailable = completedResolver.resolve(coordinatedBy: .completed(nil))
        let cachedResolver = UpdateRelaunchResumeIndexResolver(
            cachedIndexes: {
                events.append("cache-hit")
                return indexes
            }
        )
        let pendingWithCache = cachedResolver.resolve(coordinatedBy: .pending)
        let coldResolver = UpdateRelaunchResumeIndexResolver(
            cachedIndexes: {
                events.append("cache-miss")
                return nil
            }
        )
        let pendingWithoutCache = coldResolver.resolve(coordinatedBy: .pending)

        #expect(
            completed.map { _ in true } == true
                && unavailable.map { _ in true } == nil
                && pendingWithCache.map { _ in true } == nil
                && pendingWithoutCache.map { _ in true } == nil
                && events.isEmpty
        )
    }
}
