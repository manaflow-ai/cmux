import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the verified breadcrumb (U12/R15/KTD12): a
/// verified binding with a transcript path stays privacy-safe, an unverified
/// verdict produces no breadcrumb at all, and path fragments used elsewhere are
/// sanitized to stay a single safe line.
@Suite struct ResumeBreadcrumbAnchorTests {

    private func anchor(
        name: String = "Fix order-to-go CLI",
        kind: RestorableAgentKind = .claude,
        path: String? = "/Users/me/.claude/projects/-Users-me-repo/sess-123.jsonl"
    ) -> ResumeBreadcrumbBuilder.VerifiedResumeAnchor {
        ResumeBreadcrumbBuilder.VerifiedResumeAnchor(
            workspaceName: name,
            agentKind: kind,
            transcriptPath: path
        )
    }

    @Test func verifiedWithPathNamesSummaryWithoutExposingTranscript() {
        let text = ResumeBreadcrumbBuilder.breadcrumb(forVerified: anchor())
        #expect(text.contains("Fix order-to-go CLI"))
        #expect(!text.contains("/Users/me/.claude/projects/-Users-me-repo/sess-123.jsonl"))
        #expect(!text.contains("sess-123.jsonl"))
        #expect(text.localizedCaseInsensitiveContains("pick up where we left off"))
        #expect(!text.contains("\n"))
    }

    @Test func verifiedWithoutPathFallsBackToSummaryNudge() {
        let text = ResumeBreadcrumbBuilder.breadcrumb(forVerified: anchor(path: nil))
        #expect(text.contains("Fix order-to-go CLI"))
        #expect(text.localizedCaseInsensitiveContains("review your context"))
        #expect(!text.localizedCaseInsensitiveContains("transcript"))
        #expect(!text.contains("\n"))
    }

    @Test func unverifiedVerdictProducesNoBreadcrumb() {
        // Covers R15: a context-less / mis-mapped window gets no confident nudge.
        for reason: UnverifiedReason in [.noBinding, .transcriptMissing, .cwdMismatch, .noSessionId] {
            #expect(ResumeBreadcrumbBuilder.breadcrumbIfVerified(.unverified(reason), anchor: anchor()) == nil)
        }
    }

    @Test func verifiedVerdictProducesAnchoredBreadcrumb() {
        let text = ResumeBreadcrumbBuilder.breadcrumbIfVerified(.verified, anchor: anchor())
        #expect(text != nil)
        #expect(text?.contains("sess-123.jsonl") == false)
    }

    @Test func emptyNameWithPathStillOmitsTranscript() {
        let text = ResumeBreadcrumbBuilder.breadcrumb(forVerified: anchor(name: "   "))
        #expect(!text.contains("\"\""))
        #expect(!text.contains("sess-123.jsonl"))
        #expect(text.localizedCaseInsensitiveContains("pick up where we left off"))
    }

    // MARK: - Path sanitization

    @Test func tildePathIsExpanded() {
        let cleaned = ResumeBreadcrumbBuilder.sanitizedPath("~/.claude/projects/x/sess.jsonl")
        #expect(cleaned != nil)
        #expect(cleaned?.contains("~/") == false)
        #expect(cleaned?.contains("/.claude/projects/x/sess.jsonl") == true)
    }

    @Test func pathPreservesSpacesButStripsControlChars() {
        let cleaned = ResumeBreadcrumbBuilder.sanitizedPath("/Users/me/My Project/sess\n.jsonl")
        #expect(cleaned != nil)
        #expect(cleaned?.contains("My Project") == true) // internal space kept
        #expect(cleaned?.contains("\n") == false)
    }

    @Test func pathStripsUnicodeLineAndParagraphSeparators() {
        // U+2028 / U+2029 are category Zl/Zp, NOT controlCharacters; some agents
        // treat them as a line break and would submit the prompt early.
        let cleaned = ResumeBreadcrumbBuilder.sanitizedPath("/Users/me/a\u{2028}b\u{2029}c/sess.jsonl")
        #expect(cleaned != nil)
        #expect(cleaned?.contains("\u{2028}") == false)
        #expect(cleaned?.contains("\u{2029}") == false)
        // And the composed breadcrumb stays single-line.
        let text = ResumeBreadcrumbBuilder.breadcrumb(
            forVerified: anchor(path: "/Users/me/a\u{2028}b/sess.jsonl")
        )
        #expect(text.contains("\u{2028}") == false)
        #expect(!text.contains("\n"))
    }

    @Test func pathSanitizerRejectsEmptyAndCapsLength() {
        #expect(ResumeBreadcrumbBuilder.sanitizedPath(nil) == nil)
        #expect(ResumeBreadcrumbBuilder.sanitizedPath("   \n ") == nil)
        let long = "/" + String(repeating: "a", count: 600)
        let capped = ResumeBreadcrumbBuilder.sanitizedPath(long, maxLength: 100)
        #expect(capped != nil)
        #expect((capped?.count ?? 0) <= 101) // 100 + ellipsis
    }

    @Test func quotesInPathCannotBreakInjection() {
        let cleaned = ResumeBreadcrumbBuilder.sanitizedPath("/Users/me/a\"b/sess.jsonl")
        #expect(cleaned?.contains("\"") == false)

        let text = ResumeBreadcrumbBuilder.honestRecoveryPrompt(
            workspaceName: "task",
            cwd: "/Users/me/a\"b/sess.jsonl"
        )
        #expect(!text.contains("\""))
    }
}
