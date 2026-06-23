import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the pure parser for the `@cmux_git` hook payload (branch + PR for a
/// remote ssh-tmux mirror). The remote git/gh probe + tmux delivery were verified
/// live; these lock the JSON contract and the gh-state→status mapping. The exact
/// JSON shape asserted here is the one the remote hook emits (validated live):
/// `{"branch":"…","dirty":0,"pr":{"number":N,"state":"MERGED","url":"…"}}`.
@Suite struct RemoteTmuxGitStatusTests {
    typealias Git = RemoteTmuxGitStatus

    @Test func parsesBranchAndPullRequestFromLiveShape() {
        let raw = #"{"branch":"fix/1483-office","dirty":0,"pr":{"number":1815,"state":"MERGED","url":"https://github.com/GymPod/realtime-core/pull/1815"}}"#
        let g = try! #require(Git.parse(raw))
        #expect(g.branch == "fix/1483-office")
        #expect(g.isDirty == false)
        let pr = try! #require(g.pullRequest)
        #expect(pr.number == 1815)
        #expect(pr.status == .merged)
        #expect(pr.url.absoluteString == "https://github.com/GymPod/realtime-core/pull/1815")
        #expect(pr.label == "GymPod/realtime-core")
    }

    @Test func parsesDirtyAsIntStringOrBool() {
        #expect(Git.parse(#"{"branch":"main","dirty":1}"#)?.isDirty == true)
        #expect(Git.parse(#"{"branch":"main","dirty":"1"}"#)?.isDirty == true)
        #expect(Git.parse(#"{"branch":"main","dirty":true}"#)?.isDirty == true)
        #expect(Git.parse(#"{"branch":"main","dirty":0}"#)?.isDirty == false)
    }

    @Test func mapsGhStateToStatus() {
        func status(_ s: String) -> RemoteTmuxGitStatus.PullRequestStatus? {
            Git.parse(#"{"branch":"b","pr":{"number":1,"state":"\#(s)","url":"https://x/owner/repo/pull/1"}}"#)?.pullRequest?.status
        }
        #expect(status("OPEN") == .open)
        #expect(status("MERGED") == .merged)
        #expect(status("CLOSED") == .closed)
        #expect(status("open") == .open) // case-insensitive
    }

    @Test func branchOnlyWhenNoPR() {
        let g = try! #require(Git.parse(#"{"branch":"feature/x","dirty":1}"#))
        #expect(g.branch == "feature/x")
        #expect(g.isDirty)
        #expect(g.pullRequest == nil)
    }

    @Test func dropsInvalidOrIncompletePR() {
        // PR without a valid url or number is dropped (branch still kept).
        #expect(Git.parse(#"{"branch":"b","pr":{"number":1}}"#)?.pullRequest == nil)
        #expect(Git.parse(#"{"branch":"b","pr":{"url":"https://x/o/r/pull/1"}}"#)?.pullRequest == nil)
        // non-http url rejected
        #expect(Git.parse(#"{"branch":"b","pr":{"number":1,"url":"ssh://x"}}"#)?.pullRequest == nil)
    }

    @Test func returnsNilWhenEmptyOrNothingUseful() {
        #expect(Git.parse("") == nil)
        #expect(Git.parse("   ") == nil)
        #expect(Git.parse("{}") == nil)            // no branch, no pr
        #expect(Git.parse(#"{"dirty":1}"#) == nil) // dirty alone is not a row
        #expect(Git.parse("not json") == nil)
    }

    @Test func repoLabelDerivedFromPullURL() {
        #expect(Git.repoLabel(from: URL(string: "https://github.com/owner/repo/pull/42")!) == "owner/repo")
        #expect(Git.repoLabel(from: URL(string: "https://github.com/owner/repo")!) == nil)
    }

    @Test func unknownPRStateFallsBackToOpen() {
        // A state gh shouldn't emit defaults to open rather than dropping the PR.
        let g = try! #require(Git.parse(#"{"branch":"b","pr":{"number":7,"state":"DRAFT","url":"https://github.com/o/r/pull/7"}}"#))
        #expect(g.pullRequest?.status == .open)
    }
}
