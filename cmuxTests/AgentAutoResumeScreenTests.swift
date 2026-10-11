import CMUXMobileCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Agent auto-resume screen safety")
struct AgentAutoResumeScreenTests {
    @Test func stalledGoalDoesNotOverrideDraft() throws {
        let frame = try screen([
            "Selected model is at capacity",
            "› do not replace this draft",
            "Goal stalled (/goal resume)"
        ], cursorRow: 1)
        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .draft)
    }

    @Test func stalledGoalDoesNotOverrideDialog() throws {
        let frame = try screen([
            "Approve this command?",
            "press enter to confirm · esc to cancel",
            "Goal stalled (/goal resume)"
        ], cursorRow: nil)
        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .dialog)
    }

    @Test func emptyComposerRecognizesCombinedStalledFooter() throws {
        let frame = try screen([
            "Selected model is at capacity",
            "› ",
            "",
            "GPT-5.6-Sol · /tmp/project     Goal stalled (/goal resume)"
        ], cursorRow: 1)
        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .codexGoalResume)
    }

    @Test func stalledFooterWithoutAnActiveComposerDoesNotResume() throws {
        let frame = try screen([
            "› ",
            "Goal stalled (/goal resume)"
        ], cursorRow: nil)
        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .unknown)
    }

    @Test func wrappedDraftWithCursorOnPromptDoesNotResume() throws {
        let frame = try screen([
            "› ",
            "  draft text on a second line",
            "────────────────────────"
        ], cursorRow: 0)
        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .draft)
    }

    @Test func normalAgentStatusRowDoesNotLookLikeADraft() throws {
        let frame = try screen([
            "❯ ",
            "────────────────────────",
            "Sonnet 4.5 · ctx 12%"
        ], cursorRow: 0)
        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .emptyPrompt)
    }

    @Test func unseparatedStalledFooterDoesNotAuthorizeResume() throws {
        let frame = try screen([
            "› ",
            "Goal stalled (/goal resume)"
        ], cursorRow: 0)
        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .draft)
    }

    @Test(arguments: [
        "please inspect ctx ",
        "⏵⏵ auto mode on (shift+tab to cycle)",
        "gpt-5.5 high · 98% context left · /tmp/repo",
        "Sonnet 4.5 · ctx 12%"
    ])
    func footerShapedWrappedDraftsStillBlockResume(text: String) throws {
        let frame = try screen(["› ", text], cursorRow: 0)
        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .draft)
    }

    @Test func emptyPromptWithoutFooterDoesNotCrash() throws {
        let frame = try screen(["› "], cursorRow: 0)
        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .emptyPrompt)
    }

    @Test(arguments: [
        "gpt-5.5 high · Context 98% left · /tmp/repo · app · main",
        "gpt-5.5 high · 98% context left · /tmp/repo"
    ])
    func separatedCodexFootersDoNotLookLikeDrafts(footer: String) throws {
        let frame = try screen(["› ", "", footer], cursorRow: 0)
        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .emptyPrompt)
    }

    @Test func exactGoalPickerAllowsOnlyTheResumeSelection() throws {
        let frame = try screen([
            "Resume paused goal?",
            "Goal: Keep improving the bare goal command",
            "› 1. Resume goal   Mark it active and continue when idle",
            "  2. Leave paused  Keep it paused; use /goal resume later",
            "enter select · esc back"
        ], cursorRow: nil)
        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .codexResumePicker)
    }

    @Test func leavePausedSelectionDoesNotAutoConfirm() throws {
        let frame = try screen([
            "Resume paused goal?",
            "Goal: Keep improving the bare goal command",
            "  1. Resume goal   Mark it active and continue when idle",
            "› 2. Leave paused  Keep it paused; use /goal resume later",
            "enter select · esc back"
        ], cursorRow: nil)
        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .dialog)
    }

    @Test func oldPickerTitleCannotAuthorizeAnotherDialog() throws {
        let frame = try screen([
            "Resume paused goal?",
            "Approve this command?",
            "› 1. Yes",
            "enter select · esc back"
        ], cursorRow: nil)
        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .dialog)
    }

    private func screen(_ lines: [String], cursorRow: Int?) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: "auto-resume-test",
            stateSeq: 0,
            columns: 120,
            rows: lines.count,
            text: lines.joined(separator: "\n"),
            cursor: cursorRow.map { .init(row: $0, column: 2) }
        )
    }
}
