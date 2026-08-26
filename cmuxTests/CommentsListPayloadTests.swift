import CmuxDiffComments
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the `comments.list` reply shape built by `DiffCommentPayload`: which comments a caller sees by
/// default, and how a delivered comment is reported.
final class CommentsListPayloadTests: XCTestCase {
    /// Builds a comment fixture; pass `consumedAt` for a delivered one.
    private func makeComment(
        message: String,
        startLine: Int = 10,
        consumedAt: Date? = nil
    ) -> DiffComment {
        DiffComment(
            id: UUID(),
            filePath: "Sources/App.swift",
            side: "additions",
            startLine: startLine,
            endLine: startLine,
            endSide: nil,
            lineText: "    let value = compute()",
            message: message,
            submissionText: "Review comment\n",
            consumedAt: consumedAt,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    /// A delivered comment must not appear in the default listing.
    func testDefaultListingOmitsConsumedComments() {
        let payload = DiffCommentPayload().list(
            comments: [
                makeComment(message: "still open"),
                makeComment(message: "already delivered", startLine: 20, consumedAt: Date(timeIntervalSince1970: 2_000)),
            ],
            repoRoot: "/tmp/example-repo",
            includeConsumed: false
        )

        XCTAssertEqual(payload["count"] as? Int, 1)
        XCTAssertEqual(payload["repo_root"] as? String, "/tmp/example-repo")
        let comments = payload["comments"] as? [[String: Any]]
        XCTAssertEqual(comments?.count, 1)
        XCTAssertEqual(comments?.first?["message"] as? String, "still open")
        XCTAssertNil(comments?.first?["consumedAt"])
    }

    /// `include_consumed` adds delivered comments and stamps `consumedAt`.
    func testIncludeConsumedListsDeliveredCommentsWithTimestamp() {
        let consumedAt = Date(timeIntervalSince1970: 2_000)
        let payload = DiffCommentPayload().list(
            comments: [
                makeComment(message: "still open"),
                makeComment(message: "already delivered", startLine: 20, consumedAt: consumedAt),
            ],
            repoRoot: "/tmp/example-repo",
            includeConsumed: true
        )

        XCTAssertEqual(payload["count"] as? Int, 2)
        let comments = payload["comments"] as? [[String: Any]]
        XCTAssertEqual(comments?.count, 2)
        let delivered = comments?.first { $0["message"] as? String == "already delivered" }
        XCTAssertEqual(
            delivered?["consumedAt"] as? String,
            ISO8601DateFormatter().string(from: consumedAt)
        )
    }

    /// The shared mapper keeps lifecycle state for non-socket callers such as
    /// the diff-viewer bridge.
    func testSharedJSONCarriesConsumedTimestamp() {
        let consumedAt = Date(timeIntervalSince1970: 2_000)
        let comment = DiffCommentPayload().json(
            makeComment(message: "already delivered", consumedAt: consumedAt)
        )

        XCTAssertEqual(
            comment["consumedAt"] as? String,
            ISO8601DateFormatter().string(from: consumedAt)
        )
    }

    /// A listed comment keeps the anchor fields a caller re-anchors from.
    func testListedCommentCarriesAnchorFields() {
        let payload = DiffCommentPayload().list(
            comments: [makeComment(message: "needs a guard")],
            repoRoot: "/tmp/example-repo",
            includeConsumed: false
        )

        let comment = (payload["comments"] as? [[String: Any]])?.first
        XCTAssertEqual(comment?["filePath"] as? String, "Sources/App.swift")
        XCTAssertEqual(comment?["side"] as? String, "additions")
        XCTAssertEqual(comment?["startLine"] as? Int, 10)
        XCTAssertEqual(comment?["endLine"] as? Int, 10)
        XCTAssertEqual(comment?["lineText"] as? String, "    let value = compute()")
    }

    /// An empty store reports zero rather than omitting the count.
    func testEmptyStoreReportsZeroCount() {
        let payload = DiffCommentPayload().list(
            comments: [],
            repoRoot: "/tmp/example-repo",
            includeConsumed: true
        )

        XCTAssertEqual(payload["count"] as? Int, 0)
        XCTAssertEqual((payload["comments"] as? [[String: Any]])?.isEmpty, true)
    }
}
