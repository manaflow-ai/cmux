import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct NotificationBannerCompositionTests {
    @Test func agentNotificationWithWorkspaceUsesWorkspaceTitleAndAgentSubtitle() {
        let content = NotificationBannerComposer.composeNotificationBannerContent(
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
        let content = NotificationBannerComposer.composeNotificationBannerContent(
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
        let content = NotificationBannerComposer.composeNotificationBannerContent(
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
        let content = NotificationBannerComposer.composeNotificationBannerContent(
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
        let content = NotificationBannerComposer.composeNotificationBannerContent(
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
        let content = NotificationBannerComposer.composeNotificationBannerContent(
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
        let padded = NotificationBannerComposer.composeNotificationBannerContent(
            title: " My Title ",
            subtitle: "",
            body: "Y",
            agentId: nil,
            workspaceTitle: nil,
            appName: "cmux DEV"
        )
        #expect(padded.title == " My Title ")
        #expect(padded.subtitle == "")

        let whitespace = NotificationBannerComposer.composeNotificationBannerContent(
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

    @Test func bannerBodyRedactsSecretsForEveryProducer() {
        let content = NotificationBannerComposer.composeNotificationBannerContent(
            title: "Claude Code",
            subtitle: "Completed",
            body: "Finished: deploy with API_TOKEN=sk-abc123",
            agentId: "claude",
            workspaceTitle: "Fix login flow",
            appName: "cmux"
        )

        #expect(!content.body.contains("sk-abc123"))
        #expect(content.body.contains("<redacted-secret>"))
        #expect(content.title == "Fix login flow")
    }

    @Test func jsonBlobAssistantMessageDetectionParsesOnlyJSONObjectOrArrayText() {
        #expect(NotificationBannerComposer.isJSONBlobAssistantMessage(#"{"findings":[]}"#))
        #expect(NotificationBannerComposer.isJSONBlobAssistantMessage(#"  [1,2,3]  "#))
        #expect(NotificationBannerComposer.isJSONBlobAssistantMessage("{\n  \"findings\": [\"\(String(repeating: "x", count: 220))\"]\n}"))
        #expect(!NotificationBannerComposer.isJSONBlobAssistantMessage("Finished with changes"))
        #expect(!NotificationBannerComposer.isJSONBlobAssistantMessage("{not json}"))
    }

    @Test func longJSONAssistantMessageFallsBackToPromptBodyBeforeSnippet() throws {
        let assistantMessage = "{\n  \"findings\": [\"\(String(repeating: "x", count: 220))\"]\n}"
        let promptBody = try #require(NotificationBannerComposer.notificationBannerSnippet("Investigate warnings", maxLength: 120))
        let body = NotificationBannerComposer.assistantMessageSnippetRejectingJSONBlob(assistantMessage, maxLength: 180)
            ?? "Finished: \(promptBody)"

        #expect(body == "Finished: Investigate warnings")
    }

    @Test func openCodeStopDeduperDropsRepeatedTurnFingerprints() {
        let deduper = OpenCodeStopNotificationDeduper()
        let surface = UUID()
        let otherSurface = UUID()

        #expect(deduper.shouldNotify(surfaceId: surface, fingerprint: "s1|done|prompt"))
        #expect(!deduper.shouldNotify(surfaceId: surface, fingerprint: "s1|done|prompt"))
        #expect(deduper.shouldNotify(surfaceId: surface, fingerprint: "s1|next answer|prompt"))
        #expect(deduper.shouldNotify(surfaceId: otherSurface, fingerprint: "s1|done|prompt"))

        // A new user prompt re-arms the surface: an identical-text later turn
        // still notifies, so dedupe only suppresses same-turn replays.
        #expect(!deduper.shouldNotify(surfaceId: otherSurface, fingerprint: "s1|done|prompt"))
        deduper.reset(surfaceId: otherSurface)
        #expect(deduper.shouldNotify(surfaceId: otherSurface, fingerprint: "s1|done|prompt"))
    }

    @Test func openCodeStopDeduperBoundsItsMap() {
        let deduper = OpenCodeStopNotificationDeduper(capacity: 2)
        let first = UUID()

        #expect(deduper.shouldNotify(surfaceId: first, fingerprint: "a"))
        #expect(deduper.shouldNotify(surfaceId: UUID(), fingerprint: "b"))
        // Third surface trips the capacity reset and still notifies.
        #expect(deduper.shouldNotify(surfaceId: UUID(), fingerprint: "c"))
        // The reset dropped `first`; the same turn may notify once more, never loop.
        #expect(deduper.shouldNotify(surfaceId: first, fingerprint: "a"))
        #expect(!deduper.shouldNotify(surfaceId: first, fingerprint: "a"))
    }
}
