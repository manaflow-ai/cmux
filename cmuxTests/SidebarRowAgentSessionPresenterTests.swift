import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct SidebarAgentSessionAgeFormatterTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let formatter = SidebarAgentSessionAgeFormatter()

    private func age(_ secondsAgo: TimeInterval) -> String {
        formatter.text(from: now.addingTimeInterval(-secondsAgo), now: now)
    }

    @Test func boundaries() {
        #expect(age(30) == "<1m")
        #expect(age(59) == "<1m")
        #expect(age(60) == "1m")
        #expect(age(12 * 60) == "12m")
        #expect(age(59 * 60 + 59) == "59m")
        #expect(age(3_600) == "1h")
        #expect(age(23 * 3_600 + 59 * 60) == "23h")
        #expect(age(86_400) == "1d")
        #expect(age(2 * 86_400) == "2d")
    }

    @Test func futureDatesReadAsUnderAMinute() {
        #expect(age(-120) == "<1m")
    }
}

struct SidebarRowAgentSessionPresenterTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func session(
        panelId: UUID = UUID(),
        title: String = "Fix the login bug",
        lastPrompt: String? = "fix the login bug",
        state: SidebarAgentSessionSnapshot.State = .running,
        minutesAgo: TimeInterval = 12
    ) -> SidebarAgentSessionSnapshot {
        SidebarAgentSessionSnapshot(
            panelId: panelId,
            sessionID: "s-\(panelId.uuidString.prefix(4))",
            agentName: "Claude",
            title: title,
            lastPrompt: lastPrompt,
            lastPromptAt: now.addingTimeInterval(-minutesAgo * 60),
            state: state,
            lastActivityMinute: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    @Test func promptLineHiddenOnInactiveWorkspaces() {
        let rows = SidebarRowAgentSessionPresenter(now: now, lastTypedPanelId: nil)
            .rows(for: [session()], isActive: false)
        #expect(rows.count == 1)
        #expect(rows[0].promptLine == nil)
        #expect(rows[0].ageText == "12m")
        #expect(!rows[0].isLastTyped)
        #expect(rows[0].toolTip == "Fix the login bug\n\nfix the login bug")
    }

    @Test func promptLineShownOnTheActiveWorkspace() {
        let rows = SidebarRowAgentSessionPresenter(now: now, lastTypedPanelId: nil)
            .rows(for: [session()], isActive: true)
        #expect(rows[0].promptLine == "↳ fix the login bug")
    }

    @Test func lastTypedSessionShowsPromptAndMarkerEvenWhenInactive() {
        let panelId = UUID()
        let rows = SidebarRowAgentSessionPresenter(now: now, lastTypedPanelId: panelId)
            .rows(for: [session(panelId: panelId), session()], isActive: false)
        #expect(rows[0].isLastTyped)
        #expect(rows[0].promptLine == "↳ fix the login bug")
        #expect(rows[0].ageText == "12m ◀")
        #expect(!rows[1].isLastTyped)
        #expect(rows[1].promptLine == nil)
        #expect(rows[1].ageText == "12m")
    }

    @Test func missingPromptYieldsNoPromptLineAndATitleOnlyTooltip() {
        let rows = SidebarRowAgentSessionPresenter(now: now, lastTypedPanelId: nil)
            .rows(for: [session(lastPrompt: nil)], isActive: true)
        #expect(rows[0].promptLine == nil)
        #expect(rows[0].toolTip == "Fix the login bug")
    }

    @Test func newestAgeUsesTheMostRecentSession() {
        let presenter = SidebarRowAgentSessionPresenter(now: now, lastTypedPanelId: nil)
        #expect(presenter.newestAgeText(for: [session(minutesAgo: 90), session(minutesAgo: 3)]) == "3m")
        #expect(presenter.newestAgeText(for: []) == nil)
    }

    @Test func accessibilityLabelNamesAgentTitleStateAndAge() {
        let rows = SidebarRowAgentSessionPresenter(now: now, lastTypedPanelId: nil)
            .rows(for: [session(state: .needsInput)], isActive: false)
        #expect(rows[0].accessibilityLabel == "Claude: Fix the login bug, needs input, 12m")
    }
}

struct SidebarWorkspaceRowModelAgentSessionTests {
    private func display(ageText: String, promptLine: String?) -> SidebarRowAgentSessionDisplay {
        SidebarRowAgentSessionDisplay(
            panelId: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            title: "Title",
            state: .idle,
            ageText: ageText,
            isLastTyped: false,
            promptLine: promptLine,
            toolTip: "Title",
            accessibilityLabel: "Claude: Title, idle, \(ageText)"
        )
    }

    private func model(rows: [SidebarRowAgentSessionDisplay], newestAge: String?) -> SidebarWorkspaceRowModel {
        let settings = SidebarTabItemSettingsSnapshot(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let snapshot = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot()
        return SidebarWorkspaceRowModel(
            workspaceId: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!,
            index: 0,
            snapshot: snapshot,
            settings: settings,
            isActive: false,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            canCloseWorkspace: true,
            accessibilityWorkspaceCount: 1,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: false,
            rowSpacing: 8,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isGrouped: false,
            isFirstRow: true,
            shortcutHintText: nil,
            showsShortcutHints: false,
            colorSchemeIsDark: true,
            globalFontMagnificationPercent: 100,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            editingChecklistItemId: nil,
            todoControlsEnabled: false,
            isMetadataExpanded: false,
            isMarkdownExpanded: false,
            agentSessionRows: rows,
            newestAgentSessionAgeText: newestAge
        )
    }

    @Test func ageTicksAreHeightEquivalentButNotEqual() {
        let a = model(rows: [display(ageText: "12m", promptLine: nil)], newestAge: "12m")
        let b = model(rows: [display(ageText: "13m", promptLine: nil)], newestAge: "13m")
        #expect(a != b)
        #expect(a.hasHeightEquivalentContent(to: b))
    }

    @Test func promptLinePresenceChangesHeightEquivalence() {
        let a = model(rows: [display(ageText: "12m", promptLine: nil)], newestAge: "12m")
        let b = model(rows: [display(ageText: "12m", promptLine: "↳ prompt")], newestAge: "12m")
        #expect(!a.hasHeightEquivalentContent(to: b))
    }
}
