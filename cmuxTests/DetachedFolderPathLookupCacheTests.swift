import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class DetachedFolderPathLookupCacheTests: XCTestCase {
    func testCoalescesDuplicatePendingPathLookups() {
        let cache = DetachedFolderPathLookupCache<Int>(capacity: 4, maxPendingPaths: 4, maxCallbacksPerPath: 4)
        var resolvedValues: [Int] = []

        XCTAssertTrue(cache.enqueueCallback(forPath: "/remote/project") { resolvedValues.append($0) })
        XCTAssertFalse(cache.enqueueCallback(forPath: "/remote/project") { resolvedValues.append($0 * 10) })
        XCTAssertEqual(cache.pendingPathCount, 1)
        XCTAssertEqual(cache.pendingCallbackCount(forPath: "/remote/project"), 2)

        cache.resolve(path: "/remote/project", value: 3)

        XCTAssertEqual(resolvedValues, [3, 30])
        XCTAssertEqual(cache.value(forPath: "/remote/project"), 3)
        XCTAssertEqual(cache.pendingPathCount, 0)
    }

    func testPendingQueuesAreBounded() {
        let cache = DetachedFolderPathLookupCache<Int>(capacity: 4, maxPendingPaths: 1, maxCallbacksPerPath: 1)
        var resolvedValues: [Int] = []

        XCTAssertTrue(cache.enqueueCallback(forPath: "/remote/a") { resolvedValues.append($0) })
        XCTAssertFalse(cache.enqueueCallback(forPath: "/remote/a") { resolvedValues.append($0 * 10) })
        XCTAssertFalse(cache.enqueueCallback(forPath: "/remote/b") { resolvedValues.append($0 * 100) })
        XCTAssertEqual(cache.pendingPathCount, 1)
        XCTAssertEqual(cache.pendingCallbackCount(forPath: "/remote/a"), 1)

        cache.resolve(path: "/remote/a", value: 7)

        XCTAssertEqual(resolvedValues, [7])
        XCTAssertNil(cache.value(forPath: "/remote/b"))
    }

    func testResolvedValuesEvictLeastRecentlyUsedPath() {
        let cache = DetachedFolderPathLookupCache<Int>(capacity: 2)

        cache.resolve(path: "/remote/a", value: 1)
        cache.resolve(path: "/remote/b", value: 2)
        XCTAssertEqual(cache.value(forPath: "/remote/a"), 1)

        cache.resolve(path: "/remote/c", value: 3)

        XCTAssertEqual(cache.value(forPath: "/remote/a"), 1)
        XCTAssertNil(cache.value(forPath: "/remote/b"))
        XCTAssertEqual(cache.value(forPath: "/remote/c"), 3)
    }
}
