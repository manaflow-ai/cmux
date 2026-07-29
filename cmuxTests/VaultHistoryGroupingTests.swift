import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct VaultHistoryGroupingTests {
    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    /// 2026-06-18 12:00:00 UTC — a Thursday, mid-month, so every date
    /// bucket below it is reachable.
    private static let now = Date(timeIntervalSince1970: 1_781_784_000)

    private func event(
        id: String,
        secondsAgo: TimeInterval,
        kind: VaultHistoryEventKind = .workspaceCreated,
        title: String = "",
        workspaceId: UUID? = nil,
        windowId: UUID? = nil,
        agent: String? = nil,
        directory: String? = nil
    ) -> VaultHistoryEvent {
        VaultHistoryEvent(
            id: id,
            timestamp: Self.now.addingTimeInterval(-secondsAgo),
            kind: kind,
            title: title,
            subject: VaultHistorySubject(
                workspaceId: workspaceId,
                windowId: windowId,
                sessionId: agent == nil ? nil : "session-\(id)",
                agent: agent,
                directory: directory
            )
        )
    }

    // MARK: - Date bucketing

    @Test func dateBucketBoundariesAroundLast24Hours() {
        let calendar = Self.utcCalendar()
        let now = Self.now

        let justInside = now.addingTimeInterval(-24 * 3600 + 60)
        #expect(VaultHistoryDateBucket.bucket(for: justInside, now: now, calendar: calendar) == .last24Hours)

        // 24h01m ago is 11:59 the previous day: outside the rolling window,
        // inside calendar-yesterday.
        let justOutside = now.addingTimeInterval(-24 * 3600 - 60)
        #expect(VaultHistoryDateBucket.bucket(for: justOutside, now: now, calendar: calendar) == .yesterday)

        #expect(VaultHistoryDateBucket.bucket(for: now, now: now, calendar: calendar) == .last24Hours)
    }

    @Test func dateBucketCalendarBuckets() {
        let calendar = Self.utcCalendar()
        let now = Self.now

        // Tuesday 2026-06-16 08:00 UTC: same Monday-start week as Thursday
        // the 18th, older than calendar-yesterday.
        let sameWeek = Date(timeIntervalSince1970: 1_781_596_800)
        #expect(VaultHistoryDateBucket.bucket(for: sameWeek, now: now, calendar: calendar) == .thisWeek)

        // 2026-06-06: same month, previous week.
        let sameMonth = Date(timeIntervalSince1970: 1_780_704_000)
        #expect(VaultHistoryDateBucket.bucket(for: sameMonth, now: now, calendar: calendar) == .thisMonth)

        // 2026-05-18: previous month.
        let older = Date(timeIntervalSince1970: 1_779_105_600)
        #expect(VaultHistoryDateBucket.bucket(for: older, now: now, calendar: calendar) == .older)
    }

    @Test func dateGroupingOrdersBucketsNewestFirstAndSkipsEmptyBuckets() {
        let grouper = VaultHistoryGrouper(calendar: Self.utcCalendar())
        let events = [
            event(id: "older", secondsAgo: 40 * 24 * 3600),
            event(id: "recent", secondsAgo: 600),
            event(id: "yesterday", secondsAgo: 25 * 3600),
        ]
        let groups = grouper.groups(events: events, by: .date, now: Self.now)

        #expect(groups.map(\.id) == [
            "date:\(VaultHistoryDateBucket.last24Hours.rawValue)",
            "date:\(VaultHistoryDateBucket.yesterday.rawValue)",
            "date:\(VaultHistoryDateBucket.older.rawValue)",
        ])
        #expect(groups[0].events.map(\.id) == ["recent"])
        #expect(groups[1].events.map(\.id) == ["yesterday"])
        #expect(groups[2].events.map(\.id) == ["older"])
    }

    // MARK: - Group by workspace

    @Test func workspaceGroupingClustersByIdAndOrdersByRecency() {
        let grouper = VaultHistoryGrouper(calendar: Self.utcCalendar())
        let workspaceA = UUID()
        let workspaceB = UUID()
        let events = [
            event(id: "a-old", secondsAgo: 500, kind: .workspaceCreated, title: "Old name", workspaceId: workspaceA),
            event(id: "b-only", secondsAgo: 100, kind: .workspaceClosed, title: "Beta", workspaceId: workspaceB),
            event(id: "a-new", secondsAgo: 50, kind: .workspaceRenamed, title: "New name", workspaceId: workspaceA),
            event(id: "no-workspace", secondsAgo: 10, kind: .windowOpened),
        ]
        let groups = grouper.groups(events: events, by: .workspace, now: Self.now)

        #expect(groups.count == 3)
        // Groups ordered by their newest event; "Other" always trails.
        #expect(groups[0].id == "workspace:\(workspaceA.uuidString)")
        #expect(groups[1].id == "workspace:\(workspaceB.uuidString)")
        #expect(groups[2].id == VaultHistoryGrouper.otherGroupID)
        // Events inside a group stay newest-first.
        #expect(groups[0].events.map(\.id) == ["a-new", "a-old"])
        // Group title follows the newest event (the rename's new name).
        #expect(groups[0].title == "New name")
        #expect(groups[2].events.map(\.id) == ["no-workspace"])
    }

    @Test func windowGroupingClustersByWindowId() {
        let grouper = VaultHistoryGrouper(calendar: Self.utcCalendar())
        let window = UUID()
        let events = [
            event(id: "w-open", secondsAgo: 200, kind: .windowOpened, windowId: window),
            event(id: "w-close", secondsAgo: 20, kind: .windowClosed, title: "Main", windowId: window),
            event(id: "session", secondsAgo: 10, kind: .sessionActivity, title: "Fix bug", agent: "claude"),
        ]
        let groups = grouper.groups(events: events, by: .window, now: Self.now)

        #expect(groups.map(\.id) == ["window:\(window.uuidString)", VaultHistoryGrouper.otherGroupID])
        #expect(groups[0].events.map(\.id) == ["w-close", "w-open"])
    }

    // MARK: - Group by directory, agent, and kind

    @Test func directoryGroupingNormalizesPathsAndKeepsUnknownLast() {
        let grouper = VaultHistoryGrouper(calendar: Self.utcCalendar())
        let events = [
            event(
                id: "repo-old",
                secondsAgo: 300,
                title: "old",
                directory: "/tmp/project/../repo"
            ),
            event(
                id: "repo-new",
                secondsAgo: 20,
                title: "new",
                directory: "/tmp/repo/"
            ),
            event(id: "unknown", secondsAgo: 10, title: "unknown"),
        ]

        let groups = grouper.groups(events: events, by: .directory, now: Self.now)

        #expect(groups.map(\.id) == ["directory:/tmp/repo", VaultHistoryGrouper.otherGroupID])
        #expect(groups[0].title == "/tmp/repo")
        #expect(groups[0].events.map(\.id) == ["repo-new", "repo-old"])
        #expect(groups[1].events.map(\.id) == ["unknown"])
    }

    @Test func agentGroupingSeparatesAgentsFromAppEvents() {
        let grouper = VaultHistoryGrouper(calendar: Self.utcCalendar())
        let events = [
            event(id: "claude-1", secondsAgo: 30, kind: .sessionActivity, title: "s1", agent: "claude"),
            event(id: "codex-1", secondsAgo: 20, kind: .sessionActivity, title: "s2", agent: "codex"),
            event(id: "ws", secondsAgo: 10, kind: .workspaceCreated, title: "ws"),
            event(id: "claude-2", secondsAgo: 5, kind: .sessionActivity, title: "s3", agent: "claude"),
        ]
        let groups = grouper.groups(events: events, by: .agent, now: Self.now)

        #expect(groups.map(\.id) == ["agent:claude", "agent:codex", VaultHistoryGrouper.otherGroupID])
        #expect(groups[0].events.map(\.id) == ["claude-2", "claude-1"])
        #expect(groups[2].events.map(\.id) == ["ws"])
    }

    @Test func kindGroupingUsesEventKindOrderedByRecency() {
        let grouper = VaultHistoryGrouper(calendar: Self.utcCalendar())
        let events = [
            event(id: "c1", secondsAgo: 300, kind: .workspaceCreated),
            event(id: "x1", secondsAgo: 200, kind: .workspaceClosed),
            event(id: "c2", secondsAgo: 100, kind: .workspaceCreated),
        ]
        let groups = grouper.groups(events: events, by: .kind, now: Self.now)

        #expect(groups.map(\.id) == ["kind:workspaceCreated", "kind:workspaceClosed"])
        #expect(groups[0].events.map(\.id) == ["c2", "c1"])
    }

    // MARK: - Filtering, search, and sorting

    @Test func timeRangesUseRollingBoundaries() {
        let inside24Hours = event(id: "inside-24h", secondsAgo: 24 * 3600 - 1)
        let outside24Hours = event(id: "outside-24h", secondsAgo: 24 * 3600 + 1)
        let inside7Days = event(id: "inside-7d", secondsAgo: 7 * 24 * 3600 - 1)
        let outside7Days = event(id: "outside-7d", secondsAgo: 7 * 24 * 3600 + 1)
        let events = [outside7Days, inside7Days, outside24Hours, inside24Hours]

        let last24Hours = VaultHistoryQuery(timeRange: .last24Hours)
            .visibleEvents(from: events, now: Self.now)
        #expect(last24Hours.map(\.id) == ["inside-24h"])

        let last7Days = VaultHistoryQuery(timeRange: .last7Days)
            .visibleEvents(from: events, now: Self.now)
        #expect(last7Days.map(\.id) == ["inside-24h", "outside-24h", "inside-7d"])
    }

    @Test func searchMatchesEveryTokenAcrossMetadataFields() {
        let events = [
            event(
                id: "matching",
                secondsAgo: 20,
                kind: .sessionActivity,
                title: "Fix restore",
                agent: "codex",
                directory: "/Users/me/cmux"
            ),
            event(
                id: "wrong-directory",
                secondsAgo: 10,
                kind: .sessionActivity,
                title: "Fix restore",
                agent: "codex",
                directory: "/Users/me/other"
            ),
        ]
        let query = VaultHistoryQuery(searchText: "codex cmux restore")

        #expect(query.visibleEvents(from: events, now: Self.now).map(\.id) == ["matching"])
    }

    @Test func sortOrdersApplyToRowsAndDateBuckets() {
        let grouper = VaultHistoryGrouper(calendar: Self.utcCalendar())
        let events = [
            event(id: "beta-old", secondsAgo: 40 * 24 * 3600, title: "Beta"),
            event(id: "zulu-new", secondsAgo: 10, title: "Zulu"),
            event(id: "alpha-mid", secondsAgo: 25 * 3600, title: "Alpha"),
        ]

        let oldest = grouper.groups(
            events: events,
            by: .date,
            query: VaultHistoryQuery(sortOrder: .oldestFirst),
            now: Self.now
        )
        #expect(oldest.map(\.id) == [
            "date:\(VaultHistoryDateBucket.older.rawValue)",
            "date:\(VaultHistoryDateBucket.yesterday.rawValue)",
            "date:\(VaultHistoryDateBucket.last24Hours.rawValue)",
        ])

        let byTitle = VaultHistoryQuery(sortOrder: .titleAscending)
            .visibleEvents(from: events, now: Self.now)
        #expect(byTitle.map(\.id) == ["alpha-mid", "beta-old", "zulu-new"])
    }

    // MARK: - Session projection

    @Test func sessionProjectionProducesStableDerivedEvents() throws {
        let entry = SessionEntry(
            id: "abc123",
            agent: .claude,
            sessionId: "abc123",
            title: "Fix the tests",
            cwd: "/tmp/repo",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            fileURL: nil,
            specifics: .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil)
        )
        let projection = VaultHistorySessionEventProjection()

        let first = projection.events(from: [entry])
        let second = projection.events(from: [entry])
        #expect(first == second)

        let event = try #require(first.first)
        #expect(event.kind == .sessionActivity)
        #expect(event.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(event.title == "Fix the tests")
        #expect(event.subject.agent == "claude")
        #expect(event.subject.agentDisplayName == "Claude Code")
        #expect(event.subject.sessionId == "abc123")
        #expect(event.subject.directory == "/tmp/repo")
    }

    @Test func customAgentDisplayNameSurvivesProjectionAndGrouping() throws {
        let entry = SessionEntry(
            id: "custom-1",
            agent: .registered(RegisteredSessionAgent(id: "reviewer", name: "Review Bot")),
            sessionId: "custom-1",
            title: "Review changes",
            cwd: "/tmp/repo",
            gitBranch: nil,
            pullRequest: nil,
            modified: Self.now,
            fileURL: nil,
            specifics: .registered(CmuxVaultAgentRegistration(
                id: "reviewer",
                name: "Review Bot",
                detect: CmuxVaultAgentDetectRule(processName: "reviewer"),
                sessionIdSource: .argvOption("--resume"),
                resumeCommand: "reviewer --resume {{sessionId}}"
            ))
        )
        let event = try #require(VaultHistorySessionEventProjection().events(from: [entry]).first)

        #expect(event.subject.agentDisplayName == "Review Bot")
        let groups = VaultHistoryGrouper(calendar: Self.utcCalendar()).groups(
            events: [event],
            by: .agent,
            now: Self.now
        )
        #expect(groups.first?.title == "Review Bot")
    }
}
