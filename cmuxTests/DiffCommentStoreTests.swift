import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class DiffCommentStoreTests: XCTestCase {
    private func makeStore() throws -> (DiffCommentStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diff-comments-tests-\(UUID().uuidString)", isDirectory: true)
        return (DiffCommentStore(directoryURL: directory), directory)
    }

    private func makeComment(message: String = "needs a guard") -> DiffComment {
        DiffComment(
            id: UUID(),
            filePath: "Sources/App.swift",
            side: "additions",
            startLine: 10,
            endLine: 12,
            endSide: nil,
            lineText: "    let value = compute()",
            message: message,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    func testUpsertPersistsAcrossStoreInstances() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repoRoot = "/tmp/example-repo"
        let comment = makeComment()
        store.upsert(comment, repoRoot: repoRoot)

        let reloaded = DiffCommentStore(directoryURL: directory)
        let comments = reloaded.comments(repoRoot: repoRoot)
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments[0].id, comment.id)
        XCTAssertEqual(comments[0].message, comment.message)
        XCTAssertEqual(comments[0].lineText, comment.lineText)
    }

    func testUpsertExistingPreservesCreatedAt() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repoRoot = "/tmp/example-repo"
        let comment = makeComment()
        store.upsert(comment, repoRoot: repoRoot)

        var edited = comment
        edited.message = "edited"
        edited.createdAt = Date(timeIntervalSince1970: 9_999)
        let saved = store.upsert(edited, repoRoot: repoRoot)

        XCTAssertEqual(saved.createdAt, comment.createdAt)
        XCTAssertEqual(saved.message, "edited")
        XCTAssertEqual(store.comments(repoRoot: repoRoot).count, 1)
    }

    func testDeleteRemovesComment() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repoRoot = "/tmp/example-repo"
        let comment = makeComment()
        store.upsert(comment, repoRoot: repoRoot)

        XCTAssertTrue(store.delete(id: comment.id, repoRoot: repoRoot))
        XCTAssertFalse(store.delete(id: comment.id, repoRoot: repoRoot))
        XCTAssertTrue(store.comments(repoRoot: repoRoot).isEmpty)
    }

    func testReposAreIsolated() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.upsert(makeComment(), repoRoot: "/tmp/repo-a")
        XCTAssertTrue(store.comments(repoRoot: "/tmp/repo-b").isEmpty)
        XCTAssertEqual(store.comments(repoRoot: "/tmp/repo-a").count, 1)
    }

    func testRepoKeyIsStableForEquivalentPaths() {
        XCTAssertEqual(
            DiffCommentStore.repoKey(forRepoRoot: "/tmp/repo-a"),
            DiffCommentStore.repoKey(forRepoRoot: "/tmp/repo-a/")
        )
        XCTAssertNotEqual(
            DiffCommentStore.repoKey(forRepoRoot: "/tmp/repo-a"),
            DiffCommentStore.repoKey(forRepoRoot: "/tmp/repo-b")
        )
    }

    func testNilDirectoryStoreStaysInMemory() {
        let store = DiffCommentStore(directoryURL: nil)
        let comment = makeComment()
        store.upsert(comment, repoRoot: "/tmp/repo-a")
        XCTAssertEqual(store.comments(repoRoot: "/tmp/repo-a").count, 1)
    }
}

@MainActor
final class DiffCommentsAttachResolutionTests: XCTestCase {
    private func candidate(
        _ id: UUID,
        textBox: Bool
    ) -> DiffCommentsBridge.AttachCandidate {
        DiffCommentsBridge.AttachCandidate(
            surfaceId: id,
            title: "terminal",
            directory: "/tmp",
            hasActiveTextBox: textBox
        )
    }

    func testRequestedOpenerWinsWhenPresent() {
        let opener = UUID()
        let other = UUID()
        let resolution = DiffCommentsBridge.resolveAttachTarget(
            requested: opener,
            candidates: [candidate(other, textBox: true), candidate(opener, textBox: false)]
        )
        guard case .attach(let target) = resolution else {
            return XCTFail("Expected attach, got \(resolution)")
        }
        XCTAssertEqual(target, opener)
    }

    func testSingleActiveTextBoxWinsWhenOpenerGone() {
        let active = UUID()
        let resolution = DiffCommentsBridge.resolveAttachTarget(
            requested: UUID(),
            candidates: [candidate(UUID(), textBox: false), candidate(active, textBox: true)]
        )
        guard case .attach(let target) = resolution else {
            return XCTFail("Expected attach, got \(resolution)")
        }
        XCTAssertEqual(target, active)
    }

    func testSingleTerminalWinsWithoutActiveTextBox() {
        let only = UUID()
        let resolution = DiffCommentsBridge.resolveAttachTarget(
            requested: nil,
            candidates: [candidate(only, textBox: false)]
        )
        guard case .attach(let target) = resolution else {
            return XCTFail("Expected attach, got \(resolution)")
        }
        XCTAssertEqual(target, only)
    }

    func testAmbiguousTerminalsBecomePicker() {
        let resolution = DiffCommentsBridge.resolveAttachTarget(
            requested: nil,
            candidates: [candidate(UUID(), textBox: true), candidate(UUID(), textBox: true)]
        )
        guard case .picker(let candidates) = resolution else {
            return XCTFail("Expected picker, got \(resolution)")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    func testNoTerminalsIsUnavailable() {
        let resolution = DiffCommentsBridge.resolveAttachTarget(requested: nil, candidates: [])
        guard case .unavailable = resolution else {
            return XCTFail("Expected unavailable, got \(resolution)")
        }
    }
}

final class DiffCommentsBridgeTokenTests: XCTestCase {
    private let token = "0c33124b-9f59-4ba2-a2c2-9bd3b1cba001"

    func testCustomSchemePageURLYieldsToken() {
        let url = URL(string: "cmux-diff-viewer://\(token)/diff-1-abc.html")
        XCTAssertEqual(DiffCommentsBridge.diffViewerToken(from: url), token)
    }

    func testLocalServerPageWithOriginalFragmentYieldsToken() {
        let url = URL(string: "http://127.0.0.1:5050/\(token)/diff-1-abc.html#cmux-diff-viewer")
        XCTAssertEqual(DiffCommentsBridge.diffViewerToken(from: url), token)
    }

    func testLocalServerPageWithRouterRewrittenFragmentYieldsToken() {
        // The in-page router rewrites the fragment to "/cmux-diff-viewer"
        // after boot; live bridge messages carry this form.
        let url = URL(string: "http://127.0.0.1:5050/\(token)/diff-1-abc.html#/cmux-diff-viewer")
        XCTAssertEqual(DiffCommentsBridge.diffViewerToken(from: url), token)
    }

    func testNonLoopbackAndMalformedURLsAreRejected() {
        XCTAssertNil(DiffCommentsBridge.diffViewerToken(
            from: URL(string: "http://example.com/\(token)/diff-1-abc.html")
        ))
        XCTAssertNil(DiffCommentsBridge.diffViewerToken(
            from: URL(string: "http://127.0.0.1:5050/not-a-token/diff.html")
        ))
        XCTAssertNil(DiffCommentsBridge.diffViewerToken(
            from: URL(string: "http://127.0.0.1:5050/\(token)/../escape.html")
        ))
        XCTAssertNil(DiffCommentsBridge.diffViewerToken(from: nil))
    }
}
