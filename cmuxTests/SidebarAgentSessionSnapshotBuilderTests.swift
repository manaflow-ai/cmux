import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct SidebarAgentSessionSnapshotBuilderTests {
    private func record(
        _ sessionID: String,
        kind: ChatAgentKind = .claude,
        state: ChatAgentState = .idle,
        aiTitle: String? = nil,
        lastPrompt: String? = nil,
        lastActivityAt: Date = Date(timeIntervalSince1970: 3_659)
    ) -> AgentChatSessionRecord {
        var record = AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: kind,
            workspaceID: nil,
            surfaceID: nil,
            workingDirectory: nil,
            transcriptPath: nil,
            state: state,
            lastActivityAt: lastActivityAt,
            title: nil,
            pid: nil
        )
        record.aiTitle = aiTitle
        record.lastPrompt = lastPrompt
        return record
    }

    @Test func rowsFollowTabOrderAndSkipPanesWithoutASession() {
        let a = UUID(), b = UUID(), c = UUID()
        let records: [UUID: AgentChatSessionRecord] = [
            c: record("c", state: .working(since: Date()), aiTitle: "C title"),
            a: record("a", kind: .codex),
        ]
        let rows = SidebarAgentSessionSnapshotBuilder().sessions(
            orderedPanelIds: [a, b, c],
            liveRecord: { records[$0] },
            paneTitle: { _ in "✳ pane" }
        )
        #expect(rows.map(\.panelId) == [a, c])
        #expect(rows.map(\.sessionID) == ["a", "c"])
        #expect(rows[0].title == "pane")
        #expect(rows[0].agentName == "Codex")
        #expect(rows[1].title == "C title")
        #expect(rows[1].state == .running)
    }

    @Test func endedAndForeignAgentsGetNoRow() {
        let ended = UUID(), pi = UUID()
        let records: [UUID: AgentChatSessionRecord] = [
            ended: record("e", state: .ended),
            pi: record("p", kind: .other("pi")),
        ]
        let rows = SidebarAgentSessionSnapshotBuilder().sessions(
            orderedPanelIds: [ended, pi],
            liveRecord: { records[$0] },
            paneTitle: { _ in nil }
        )
        #expect(rows.isEmpty)
    }

    @Test func titleFallsBackFromClaudeTitleToPaneTitleToAgentName() {
        #expect(SidebarAgentSessionSnapshotBuilder.resolvedTitle(aiTitle: "X", paneTitle: "Y", agentName: "Claude") == "X")
        #expect(SidebarAgentSessionSnapshotBuilder.resolvedTitle(aiTitle: nil, paneTitle: "✳ Thinking", agentName: "Claude") == "Thinking")
        #expect(SidebarAgentSessionSnapshotBuilder.resolvedTitle(aiTitle: "  ", paneTitle: nil, agentName: "Claude") == "Claude")
        #expect(SidebarAgentSessionSnapshotBuilder.resolvedTitle(aiTitle: nil, paneTitle: "◐", agentName: "Codex") == "Codex")
    }

    @Test func spinnerGlyphsAreStrippedOnlyFromTheFront() {
        #expect(SidebarAgentSessionSnapshotBuilder.strippingSpinnerGlyphs("◐◑  Fix it") == "Fix it")
        #expect(SidebarAgentSessionSnapshotBuilder.strippingSpinnerGlyphs("✳ Claude Code") == "Claude Code")
        #expect(SidebarAgentSessionSnapshotBuilder.strippingSpinnerGlyphs("Fix it ✳") == "Fix it ✳")
    }

    @Test func activityIsFlooredToTheMinute() {
        let floored = SidebarAgentSessionSnapshotBuilder.flooredToMinute(Date(timeIntervalSince1970: 3_659))
        #expect(floored == Date(timeIntervalSince1970: 3_600))
        let rows = SidebarAgentSessionSnapshotBuilder().sessions(
            orderedPanelIds: [UUID()],
            liveRecord: { _ in record("s", lastActivityAt: Date(timeIntervalSince1970: 3_659)) },
            paneTitle: { _ in nil }
        )
        #expect(rows.first?.lastActivityMinute == Date(timeIntervalSince1970: 3_600))
    }

    @Test func stateMapping() {
        #expect(SidebarAgentSessionSnapshotBuilder.state(for: .idle) == .idle)
        #expect(SidebarAgentSessionSnapshotBuilder.state(for: .working(since: Date())) == .running)
        #expect(SidebarAgentSessionSnapshotBuilder.state(for: .needsInput(since: Date())) == .needsInput)
        #expect(SidebarAgentSessionSnapshotBuilder.state(for: .ended) == nil)
    }
}
