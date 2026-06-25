import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the resume breadcrumb builder: the prompt anchors on the
/// workspace name, sanitizes hostile names so injection stays single-line, and
/// degrades cleanly when the name is empty.
@Suite struct ResumeBreadcrumbBuilderTests {

    @Test func breadcrumbContainsNameAndResumeInstruction() {
        let text = ResumeBreadcrumbBuilder.breadcrumb(
            workspaceName: "last30days big new release",
            agent: .claude
        )
        #expect(text.contains("last30days big new release"))
        #expect(text.localizedCaseInsensitiveContains("pick up where we left off"))
        // Single line — safe to deliver as startup input.
        #expect(!text.contains("\n"))
    }

    @Test func bothSupportedAgentsProduceUsablePrompts() {
        for agent in [RestorableAgentKind.claude, .codex] {
            let text = ResumeBreadcrumbBuilder.breadcrumb(workspaceName: "Fix auth bug", agent: agent)
            #expect(text.contains("Fix auth bug"))
            #expect(text.localizedCaseInsensitiveContains("pick up where we left off"))
        }
    }

    @Test func emptyNameUsesGenericFallbackWithNoDanglingQuotes() {
        let text = ResumeBreadcrumbBuilder.breadcrumb(workspaceName: "   ", agent: .claude)
        #expect(!text.contains("\"\""))
        #expect(!text.contains("\" \""))
        #expect(text.localizedCaseInsensitiveContains("pick up where we left off"))
    }

    @Test func newlinesAndControlCharsAreCollapsedToSingleLine() {
        let hostile = "Clarify\nunclear\tconnection\r\n; rm -rf"
        let text = ResumeBreadcrumbBuilder.breadcrumb(workspaceName: hostile, agent: .codex)
        #expect(!text.contains("\n"))
        #expect(!text.contains("\t"))
        #expect(!text.contains("\r"))
        #expect(text.contains("Clarify unclear connection"))
    }

    @Test func embeddedQuotesAreRemovedFromQueuedPrompt() {
        let text = ResumeBreadcrumbBuilder.breadcrumb(workspaceName: "the \"big\" release", agent: .claude)
        #expect(!text.contains("\""))
        #expect(text.contains("the big release"))
    }

    @Test func queuedPromptRemovesShellMetacharactersFromTemplateAndFragments() {
        let text = ResumeBreadcrumbBuilder.honestRecoveryPrompt(
            workspaceName: "ship $(touch /tmp/pwn) `date` \\ ; | &",
            cwd: "/tmp/cmux-$(touch pwn);repo`date`\\x"
        )
        for character in ["$", "`", "\\", ";", "|", "&", "\"", "'", "(", ")"] {
            #expect(!text.contains(character))
        }
    }

    @Test func sanitizerReturnsNilForEmptyAndCapsLength() {
        #expect(ResumeBreadcrumbBuilder.sanitizedName("") == nil)
        #expect(ResumeBreadcrumbBuilder.sanitizedName("   \n\t ") == nil)
        let long = String(repeating: "a", count: 500)
        let capped = ResumeBreadcrumbBuilder.sanitizedName(long, maxLength: 50)
        #expect(capped != nil)
        #expect((capped?.count ?? 0) <= 51) // 50 + ellipsis
    }

    @Test func onlyClaudeAndCodexAreSupportedInV1() {
        #expect(ResumeBreadcrumbBuilder.isSupported(.claude))
        #expect(ResumeBreadcrumbBuilder.isSupported(.codex))
        #expect(!ResumeBreadcrumbBuilder.isSupported(.gemini))
        #expect(!ResumeBreadcrumbBuilder.isSupported(.custom("acme")))
    }
}
