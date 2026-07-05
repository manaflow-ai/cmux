import CMUXAgentLaunch
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct FeedNotificationContentTests {
    @Test func permissionBodyUsesCommandDetail() throws {
        let content = try #require(NotificationBannerComposer.composeFeedNotificationContent(
            hookEventName: .permissionRequest,
            source: "opencode",
            toolName: "Bash",
            toolInputJSON: #"{"command":"git status --short"}"#,
            workspaceTitle: "cmux"
        ))

        #expect(content.title == "cmux")
        #expect(content.subtitle == "OpenCode \u{00B7} permission")
        #expect(content.body == "Allow Bash: git status --short")
    }

    @Test func permissionBodyUsesFileBasename() throws {
        let content = try #require(NotificationBannerComposer.composeFeedNotificationContent(
            hookEventName: .permissionRequest,
            source: "codex",
            toolName: "Edit",
            toolInputJSON: #"{"file_path":"/tmp/work/README.md"}"#,
            workspaceTitle: nil
        ))

        #expect(content.title == "Codex permission")
        #expect(content.subtitle == "Codex \u{00B7} permission")
        #expect(content.body == "Allow Edit: README.md")
    }

    @Test func permissionBodyUsesFirstPattern() throws {
        let content = try #require(NotificationBannerComposer.composeFeedNotificationContent(
            hookEventName: .permissionRequest,
            source: "claude",
            toolName: "Read",
            toolInputJSON: #"{"patterns":["Sources/**/*.swift","Tests/**/*.swift"]}"#,
            workspaceTitle: "Workspace"
        ))

        #expect(content.title == "Workspace")
        #expect(content.subtitle == "Claude Code \u{00B7} permission")
        #expect(content.body == "Allow Read: Sources/**/*.swift")
    }

    @Test func permissionBodyUsesSingleToolApprovalForOpaqueInput() throws {
        let content = try #require(NotificationBannerComposer.composeFeedNotificationContent(
            hookEventName: .permissionRequest,
            source: "custom",
            toolName: "Shell",
            toolInputJSON: "not-json",
            workspaceTitle: nil
        ))

        #expect(content.title == "custom permission")
        #expect(content.subtitle == "custom \u{00B7} permission")
        #expect(content.body == "Shell needs approval")
    }

    @Test func permissionBodyRedactsSecretsInCommandDetail() throws {
        let content = try #require(NotificationBannerComposer.composeFeedNotificationContent(
            hookEventName: .permissionRequest,
            source: "claude",
            toolName: "Bash",
            toolInputJSON: #"{"command":"API_TOKEN=sk-abc123 ./deploy.sh"}"#,
            workspaceTitle: nil
        ))

        #expect(!content.body.contains("sk-abc123"))
        #expect(content.body.contains("<redacted-secret>"))
        #expect(content.body.hasPrefix("Allow Bash: "))
    }

    @Test func questionBodyUsesFirstQuestionText() throws {
        let content = try #require(NotificationBannerComposer.composeFeedNotificationContent(
            hookEventName: .askUserQuestion,
            source: "opencode",
            toolName: nil,
            toolInputJSON: #"{"questions":[{"question":"Which branch should I use?"}]}"#,
            workspaceTitle: "cmux"
        ))

        #expect(content.title == "cmux")
        #expect(content.subtitle == "OpenCode \u{00B7} question")
        #expect(content.body == "Which branch should I use?")
    }

    @Test func exitPlanBodyUsesQuestionThenPlanLine() throws {
        let questionContent = try #require(NotificationBannerComposer.composeFeedNotificationContent(
            hookEventName: .exitPlanMode,
            source: "codex",
            toolName: nil,
            toolInputJSON: #"{"tool_input":{"question":"Approve this plan?"}}"#,
            workspaceTitle: "cmux"
        ))
        #expect(questionContent.title == "cmux")
        #expect(questionContent.subtitle == "Codex \u{00B7} plan ready")
        #expect(questionContent.body == "Approve this plan?")

        let planContent = try #require(NotificationBannerComposer.composeFeedNotificationContent(
            hookEventName: .exitPlanMode,
            source: "codex",
            toolName: nil,
            toolInputJSON: #"{"plan":"\n\n1. Update notifications\n2. Add tests"}"#,
            workspaceTitle: nil
        ))
        #expect(planContent.title == "Codex plan ready")
        #expect(planContent.subtitle == "Codex \u{00B7} plan ready")
        #expect(planContent.body == "1. Update notifications")
    }
}
