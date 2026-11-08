import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Native persistence for the diff viewer's per-file "Viewed" state, keyed by
/// (repository root, diff source identity, file path) with the patch
/// fingerprint recorded at the time the file was marked viewed.
final class DiffViewerViewedFilesStoreTests: XCTestCase {
    /// The store writes on `queue`; `queue.sync {}` waits for queued writes.
    private func makeStore() -> (DiffViewerViewedFilesStore, URL, DispatchQueue) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diff-viewer-viewed-tests-\(UUID().uuidString)", isDirectory: true)
        let queue = DispatchQueue(label: "diff-viewer-viewed-tests")
        return (DiffViewerViewedFilesStore(directoryURL: directory, persistenceQueue: queue), directory, queue)
    }

    private var unstaged: DiffViewerViewedFilesStore.Scope {
        DiffViewerViewedFilesStore.Scope(repoRoot: "/tmp/example-repo", source: "unstaged")
    }

    func testMarkViewedPersistsAcrossStoreInstances() throws {
        let (store, directory, queue) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.markViewed(scope: unstaged, path: "Sources/App.swift", fingerprint: "abcd1234")
        queue.sync {}

        let reloaded = DiffViewerViewedFilesStore(directoryURL: directory)
        let entries = reloaded.entries(scope: unstaged)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.path, "Sources/App.swift")
        XCTAssertEqual(entries.first?.fingerprint, "abcd1234")
    }

    func testScopesAreIsolatedByRepoAndSource() throws {
        let (store, directory, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = DiffViewerViewedFilesStore.Scope(repoRoot: "/tmp/example-repo", source: "staged")
        let otherRepo = DiffViewerViewedFilesStore.Scope(repoRoot: "/tmp/other-repo", source: "unstaged")
        store.markViewed(scope: unstaged, path: "a.txt", fingerprint: "1")
        store.markViewed(scope: staged, path: "b.txt", fingerprint: "2")

        XCTAssertEqual(store.entries(scope: unstaged).map(\.path), ["a.txt"])
        XCTAssertEqual(store.entries(scope: staged).map(\.path), ["b.txt"])
        XCTAssertTrue(store.entries(scope: otherRepo).isEmpty)
        // Non-canonical spellings of the same repository share a scope.
        let trailingSlash = DiffViewerViewedFilesStore.Scope(repoRoot: "/tmp/example-repo/", source: "unstaged")
        XCTAssertEqual(store.entries(scope: trailingSlash).map(\.path), ["a.txt"])
    }

    func testMarkViewedReplacesTheFingerprintAndClearRemovesTheEntry() throws {
        let (store, directory, queue) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.markViewed(scope: unstaged, path: "a.txt", fingerprint: "old")
        store.markViewed(scope: unstaged, path: "a.txt", fingerprint: "new")
        XCTAssertEqual(store.entries(scope: unstaged).map(\.fingerprint), ["new"])

        XCTAssertTrue(store.clear(scope: unstaged, path: "a.txt"))
        XCTAssertFalse(store.clear(scope: unstaged, path: "a.txt"))
        queue.sync {}
        XCTAssertTrue(DiffViewerViewedFilesStore(directoryURL: directory).entries(scope: unstaged).isEmpty)
    }

    func testStoreEvictsOldestEntriesBeyondThePerScopeBound() throws {
        let (store, directory, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bound = DiffViewerViewedFilesStore.maxEntriesPerScope
        for index in 0...bound {
            store.markViewed(
                scope: unstaged,
                path: "file-\(index).txt",
                fingerprint: "f",
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let entries = store.entries(scope: unstaged)
        XCTAssertEqual(entries.count, bound)
        XCTAssertFalse(entries.contains { $0.path == "file-0.txt" })
        XCTAssertTrue(entries.contains { $0.path == "file-\(bound).txt" })
    }

    func testStoreBoundsTheNumberOfScopeFiles() throws {
        let (store, directory, queue) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bound = DiffViewerViewedFilesStore.maxScopes
        for index in 0...bound {
            let scope = DiffViewerViewedFilesStore.Scope(repoRoot: "/tmp/repo-\(index)", source: "unstaged")
            store.markViewed(
                scope: scope,
                path: "a.txt",
                fingerprint: "f",
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        queue.sync {}
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(files.count, bound)
        let oldest = DiffViewerViewedFilesStore.Scope(repoRoot: "/tmp/repo-0", source: "unstaged")
        XCTAssertTrue(DiffViewerViewedFilesStore(directoryURL: directory).entries(scope: oldest).isEmpty)
    }

    func testCorruptFileIsTreatedAsEmpty() throws {
        let (store, directory, queue) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.markViewed(scope: unstaged, path: "a.txt", fingerprint: "1")
        queue.sync {}
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files {
            try "not json".write(to: file, atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(DiffViewerViewedFilesStore(directoryURL: directory).entries(scope: unstaged).isEmpty)
    }

    func testJSONEntriesUseTheBridgeShape() throws {
        let (store, directory, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.markViewed(scope: unstaged, path: "a.txt", fingerprint: "1")
        let json = store.jsonEntries(scope: unstaged)
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(json.first?["path"] as? String, "a.txt")
        XCTAssertEqual(json.first?["fingerprint"] as? String, "1")
    }
}
