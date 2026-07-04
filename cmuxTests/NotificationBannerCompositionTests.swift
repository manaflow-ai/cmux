import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct NotificationBannerCompositionTests {
    @Test func agentNotificationWithWorkspaceUsesWorkspaceTitleAndAgentSubtitle() {
        let content = composeNotificationBannerContent(
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Review the proposed change",
            agentId: "claude",
            workspaceTitle: "cmux",
            appName: "cmux DEV"
        )

        #expect(content.title == "cmux")
        #expect(content.subtitle == "Claude Code \u{00B7} Waiting")
        #expect(content.body == "Review the proposed change")
    }

    @Test func agentNotificationWithoutWorkspaceKeepsLegacyContent() {
        let content = composeNotificationBannerContent(
            title: "Codex",
            subtitle: "Completed",
            body: "Done",
            agentId: "codex",
            workspaceTitle: nil,
            appName: "cmux DEV"
        )

        #expect(content.title == "Codex")
        #expect(content.subtitle == "Completed")
        #expect(content.body == "Done")
    }

    @Test func nonAgentNotificationUsesWorkspaceAsMissingSubtitle() {
        let content = composeNotificationBannerContent(
            title: "Build finished",
            subtitle: "",
            body: "All checks passed",
            agentId: nil,
            workspaceTitle: "cmux",
            appName: "cmux DEV"
        )

        #expect(content.title == "Build finished")
        #expect(content.subtitle == "cmux")
        #expect(content.body == "All checks passed")
    }

    @Test func nonAgentNotificationDoesNotDuplicateWorkspaceSubtitleWhenTitleMatches() {
        let content = composeNotificationBannerContent(
            title: "cmux",
            subtitle: "",
            body: "All checks passed",
            agentId: nil,
            workspaceTitle: "cmux",
            appName: "cmux DEV"
        )

        #expect(content.title == "cmux")
        #expect(content.subtitle == "")
        #expect(content.body == "All checks passed")
    }

    @Test func nonAgentNotificationKeepsExistingSubtitle() {
        let content = composeNotificationBannerContent(
            title: "Build finished",
            subtitle: "Release",
            body: "All checks passed",
            agentId: nil,
            workspaceTitle: "cmux",
            appName: "cmux DEV"
        )

        #expect(content.title == "Build finished")
        #expect(content.subtitle == "Release")
        #expect(content.body == "All checks passed")
    }

    @Test func emptyTitleFallsBackToAppNameWhenLegacyTitleIsTrulyEmpty() {
        let content = composeNotificationBannerContent(
            title: "",
            subtitle: "",
            body: "Y",
            agentId: nil,
            workspaceTitle: nil,
            appName: "cmux DEV"
        )

        #expect(content.title == "cmux DEV")
        #expect(content.subtitle == "")
        #expect(content.body == "Y")
    }

    @Test func legacyPathPreservesPaddedAndWhitespaceOnlyTitles() {
        let padded = composeNotificationBannerContent(
            title: " My Title ",
            subtitle: "",
            body: "Y",
            agentId: nil,
            workspaceTitle: nil,
            appName: "cmux DEV"
        )
        #expect(padded.title == " My Title ")
        #expect(padded.subtitle == "")

        let whitespace = composeNotificationBannerContent(
            title: "  ",
            subtitle: "",
            body: "Y",
            agentId: nil,
            workspaceTitle: nil,
            appName: "cmux DEV"
        )
        #expect(whitespace.title == "  ")
        #expect(whitespace.subtitle == "")
    }
}
