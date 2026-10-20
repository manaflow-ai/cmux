import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct DetachedFolderPathLookupCacheTests {
    @Test func coalescesDuplicatePendingPathLookups() {
        let cache = DetachedFolderPathLookupCache<Int>(capacity: 4, maxPendingPaths: 4, maxCallbacksPerPath: 4)
        var resolvedValues: [Int] = []

        #expect(cache.enqueueCallback(forPath: "/remote/project") { resolvedValues.append($0) })
        #expect(!cache.enqueueCallback(forPath: "/remote/project") { resolvedValues.append($0 * 10) })
        #expect(cache.pendingPathCount == 1)
        #expect(cache.pendingCallbackCount(forPath: "/remote/project") == 2)

        cache.resolve(path: "/remote/project", value: 3)

        #expect(resolvedValues == [3, 30])
        #expect(cache.value(forPath: "/remote/project") == 3)
        #expect(cache.pendingPathCount == 0)
    }

    @Test func pendingQueuesAreBounded() {
        let cache = DetachedFolderPathLookupCache<Int>(capacity: 4, maxPendingPaths: 1, maxCallbacksPerPath: 1)
        var resolvedValues: [Int] = []

        #expect(cache.enqueueCallback(forPath: "/remote/a") { resolvedValues.append($0) })
        #expect(!cache.enqueueCallback(forPath: "/remote/a") { resolvedValues.append($0 * 10) })
        #expect(!cache.enqueueCallback(forPath: "/remote/b") { resolvedValues.append($0 * 100) })
        #expect(cache.pendingPathCount == 1)
        #expect(cache.pendingCallbackCount(forPath: "/remote/a") == 1)

        cache.resolve(path: "/remote/a", value: 7)

        #expect(resolvedValues == [7])
        #expect(cache.value(forPath: "/remote/b") == nil)
    }

    @Test func resolvedValuesEvictLeastRecentlyUsedPath() {
        let cache = DetachedFolderPathLookupCache<Int>(capacity: 2)

        cache.resolve(path: "/remote/a", value: 1)
        cache.resolve(path: "/remote/b", value: 2)
        #expect(cache.value(forPath: "/remote/a") == 1)

        cache.resolve(path: "/remote/c", value: 3)

        #expect(cache.value(forPath: "/remote/a") == 1)
        #expect(cache.value(forPath: "/remote/b") == nil)
        #expect(cache.value(forPath: "/remote/c") == 3)
    }
}
