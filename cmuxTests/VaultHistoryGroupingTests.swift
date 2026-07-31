import AppKit
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

    @Test func historyModesExposeWorkspaceFolderAndAgentPrimitives() {
        let workspaceId = UUID()
        let events = [
            event(
                id: "workspace",
                secondsAgo: 30,
                kind: .workspaceCreated,
                title: "History",
                workspaceId: workspaceId,
                directory: "/tmp/repo"
            ),
            event(
                id: "session",
                secondsAgo: 20,
                kind: .sessionActivity,
                title: "Implement History",
                agent: "codex",
                directory: "/tmp/repo"
            ),
            event(id: "window", secondsAgo: 10, kind: .windowOpened, windowId: UUID()),
        ]

        #expect(VaultHistoryMode.timeline.groupKey == .workspace)
        #expect(VaultHistoryMode.folder.groupKey == .directory)
        #expect(VaultHistoryMode.agent.groupKey == .agent)
        #expect(VaultHistoryMode.timeline.includedEvents(from: events).map(\.id) == ["workspace"])
        #expect(VaultHistoryMode.folder.includedEvents(from: events).map(\.id) == ["workspace", "session"])
        #expect(VaultHistoryMode.agent.includedEvents(from: events).map(\.id) == ["session"])
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

    @Test func appKitTimelineProjectionFlattensGroupsIntoStableVirtualRows() throws {
        let event = event(
            id: "codex-session",
            secondsAgo: 5,
            kind: .sessionActivity,
            title: "Implement History",
            agent: "codex"
        )
        let group = VaultHistoryGroup(id: "agent:codex", title: "Codex", events: [event])

        let rows = VaultHistoryTimelineList.makeRows(
            groups: [group],
            resumeEntriesByEventId: [:],
            availableClosedItemIds: [],
            actions: VaultHistoryRowActions(onResume: nil, onReopenClosedItem: nil)
        )

        #expect(rows.map(\.id) == [.group("agent:codex"), .event("codex-session")])
        guard case .group(_, _, 1, let groupAgent, nil) = rows[0] else {
            Issue.record("Expected the first virtual row to be a group header")
            return
        }
        #expect(groupAgent == .codex)
        guard case .event(_, nil, let rowAgent) = rows[1] else {
            Issue.record("Expected the second virtual row to be an event")
            return
        }
        #expect(rowAgent == .codex)
        #expect(rowAgent?.assetName == "AgentIcons/Codex")
    }

    @Test func appKitTimelineUsesRegisteredAgentIconMetadataFromSessionEntry() throws {
        let registeredAgent = SessionAgent.registered(RegisteredSessionAgent(
            id: "reviewer",
            name: "Review Bot",
            iconAssetName: "AgentIcons/Pi"
        ))
        let entry = SessionEntry(
            id: "custom-icon",
            agent: registeredAgent,
            sessionId: "custom-icon",
            title: "Review changes",
            cwd: "/tmp/repo",
            gitBranch: nil,
            pullRequest: nil,
            modified: Self.now,
            fileURL: nil,
            specifics: .registered(CmuxVaultAgentRegistration(
                id: "reviewer",
                name: "Review Bot",
                iconAssetName: "AgentIcons/Pi",
                detect: CmuxVaultAgentDetectRule(processName: "reviewer"),
                sessionIdSource: .argvOption("--resume"),
                resumeCommand: "reviewer --resume {{sessionId}}"
            ))
        )
        let event = try #require(VaultHistorySessionEventProjection().events(from: [entry]).first)
        let group = VaultHistoryGroup(id: "agent:reviewer", title: "Review Bot", events: [event])

        let rows = VaultHistoryTimelineList.makeRows(
            groups: [group],
            resumeEntriesByEventId: [event.id: entry],
            availableClosedItemIds: [],
            actions: VaultHistoryRowActions(onResume: nil, onReopenClosedItem: nil)
        )

        guard case .event(_, nil, let rowAgent) = rows[1] else {
            Issue.record("Expected a virtualized event row")
            return
        }
        #expect(rowAgent == registeredAgent)
        #expect(rowAgent?.assetName == "AgentIcons/Pi")
    }

    @Test func workspaceGroupExposesNewestAvailableRecoveryAction() throws {
        let workspaceId = UUID()
        let olderClosedItemId = UUID()
        let newestClosedItemId = UUID()
        let events = [
            VaultHistoryEvent(
                id: "older-close",
                timestamp: Self.now.addingTimeInterval(-30),
                kind: .workspaceClosed,
                title: "History",
                subject: VaultHistorySubject(
                    workspaceId: workspaceId,
                    closedItemId: olderClosedItemId,
                    directory: "/tmp/repo"
                )
            ),
            VaultHistoryEvent(
                id: "newest-close",
                timestamp: Self.now.addingTimeInterval(-10),
                kind: .workspaceClosed,
                title: "History",
                subject: VaultHistorySubject(
                    workspaceId: workspaceId,
                    closedItemId: newestClosedItemId,
                    directory: "/tmp/repo"
                )
            ),
        ]
        let group = VaultHistoryGroup(
            id: "workspace:\(workspaceId.uuidString)",
            title: "History",
            events: events
        )

        let rows = VaultHistoryTimelineList.makeRows(
            groups: [group],
            resumeEntriesByEventId: [:],
            availableClosedItemIds: [olderClosedItemId, newestClosedItemId],
            actions: VaultHistoryRowActions(
                onResume: nil,
                onReopenClosedItem: { _ in true }
            )
        )

        guard case .group(_, _, 2, nil, let action) = rows[0] else {
            Issue.record("Expected a workspace group row with a recovery action")
            return
        }
        #expect(action == .reopenClosedItem(newestClosedItemId))
    }
}

@Suite(.serialized)
struct VaultHistoryAppKitViewportTests {
    @MainActor
    @Test
    func timelineRealizesOnlyViewportRowsAtScale() async throws {
        let controller = VaultHistoryTableController()
        let container = controller.makeContainerView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.frame = window.contentView?.bounds ?? .zero

        let events = (0..<5_000).map { index in
            VaultHistoryTableRow.event(
                event: VaultHistoryEvent(
                    id: "session-\(index)",
                    timestamp: Date(timeIntervalSince1970: TimeInterval(10_000 - index)),
                    kind: .sessionActivity,
                    title: "Synthetic session \(index)",
                    subject: VaultHistorySubject(
                        sessionId: "session-\(index)",
                        agent: "codex",
                        agentDisplayName: "Codex",
                        directory: "/tmp/history-scale"
                    )
                ),
                action: nil,
                agent: .codex
            )
        }
        controller.apply(
            rows: [
                .group(
                    id: "agent:codex",
                    title: "Codex",
                    count: events.count,
                    agent: .codex,
                    action: nil
                ),
            ] + events,
            actions: VaultHistoryRowActions(onResume: nil, onReopenClosedItem: nil),
            globalFontMagnificationPercent: 100
        )

        window.contentView?.layoutSubtreeIfNeeded()
        await flushStagedTableMutations()
        window.contentView?.layoutSubtreeIfNeeded()

        let table = container.tableView
        let visibleRows = table.rows(in: table.visibleRect)
        let realizedRows = (0..<table.numberOfRows).filter { row in
            table.view(atColumn: 0, row: row, makeIfNecessary: false) != nil
        }

        #expect(table.numberOfRows == 5_001)
        #expect(visibleRows.length > 0)
        #expect(table.numberOfRows > visibleRows.length)
        #expect(realizedRows.count <= visibleRows.length + 2)
    }

    @MainActor
    @Test
    func timelineCapsRenderedTranscriptTitlesWithoutChangingStoredEvent() {
        let original = String(repeating: "session output ", count: 100)
        let event = VaultHistoryEvent(
            timestamp: Date(),
            kind: .sessionActivity,
            title: original
        )

        let rendered = VaultHistoryTableEventCellView.displayTitle(for: event)

        #expect(rendered.count == 241)
        #expect(rendered.hasSuffix("…"))
        #expect(event.title == original)
    }

    @MainActor
    @Test
    func timelineCellKeepsMultilineTranscriptInsideOneFixedHeightRow() throws {
        let event = VaultHistoryEvent(
            id: "multiline-session",
            timestamp: Date(),
            kind: .sessionActivity,
            title: "first line\n  second line\tthird line",
            subject: VaultHistorySubject(
                sessionId: "multiline-session",
                agent: "codex",
                agentDisplayName: "Codex",
                directory: "/tmp/history"
            )
        )
        let cell = VaultHistoryTableEventCellView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 38)
        )

        cell.configure(
            event: event,
            action: nil,
            agent: .codex,
            globalFontMagnificationPercent: 100,
            onPerformAction: { _ in }
        )
        cell.layoutSubtreeIfNeeded()

        let labels = Self.descendants(of: cell).compactMap { $0 as? NSTextField }
        #expect(labels.count == 3)
        #expect(labels.allSatisfy { $0.usesSingleLineMode })
        #expect(labels.allSatisfy { !$0.stringValue.contains(where: \.isNewline) })
        #expect(VaultHistoryTableEventCellView.displayTitle(for: event) == "first line second line third line")
        for label in labels {
            let frameInCell = cell.convert(label.bounds, from: label)
            #expect(cell.bounds.contains(frameInCell))
        }
    }

    @Test
    func workspaceLifecycleUsesMinimalAddRemoveSymbols() {
        #expect(VaultHistoryEventKind.workspaceCreated.symbolName == "plus")
        #expect(VaultHistoryEventKind.workspaceClosed.symbolName == "minus")
    }

    @MainActor
    private func flushStagedTableMutations() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }
    }

    @MainActor
    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
