import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func makeEntry(
    id: String,
    agent: SessionAgent = .claude,
    title: String = "session",
    cwd: String? = "/Users/dev/projects/cmux",
    branch: String? = nil,
    modified: Date,
    created: Date? = nil,
    messageCount: Int? = nil
) -> SessionEntry {
    SessionEntry(
        id: id,
        agent: agent,
        sessionId: id,
        title: title,
        cwd: cwd,
        gitBranch: branch,
        pullRequest: nil,
        modified: modified,
        fileURL: nil,
        specifics: .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil),
        created: created,
        messageCount: messageCount
    )
}

@Suite
struct VaultRecencySectionsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-08-14 12:00:00 UTC
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 12))!
    }

    private func date(_ day: Int, hour: Int, month: Int = 8) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func build(
        _ entries: [SessionEntry],
        filter: VaultSessionFilter = VaultSessionFilter(),
        sort: VaultSessionSort = .lastActivity,
        liveKeys: Set<String> = []
    ) -> [IndexSection] {
        VaultRecencySections.build(
            entries: entries,
            filter: filter,
            sort: sort,
            liveKeys: liveKeys,
            now: now,
            calendar: calendar
        )
    }

    @Test
    func bucketsByDayNewestFirstWithMidnightBoundary() {
        let lateYesterday = makeEntry(id: "y", modified: date(13, hour: 23))
        let earlyToday = makeEntry(id: "t", modified: date(14, hour: 0))
        let older = makeEntry(id: "o", modified: date(1, hour: 5))
        let sections = build([older, lateYesterday, earlyToday])
        #expect(sections.count == 3)
        #expect(sections[0].entries.map(\.id) == ["t"])
        #expect(sections[1].entries.map(\.id) == ["y"])
        #expect(sections[2].entries.map(\.id) == ["o"])
        #expect(sections[0].key.isDayBucket)
        #expect(sections[0].key.raw == "day:2026-08-14")
    }

    @Test
    func dayTitlesForTodayYesterdayWeekAndOlder() {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let midWeek = calendar.date(byAdding: .day, value: -4, to: today)!
        let older = calendar.date(byAdding: .day, value: -20, to: today)!

        #expect(VaultRecencySections.dayTitle(for: today, now: now, calendar: calendar)
            == String(localized: "sessionIndex.day.today", defaultValue: "Today"))
        #expect(VaultRecencySections.dayTitle(for: yesterday, now: now, calendar: calendar)
            == String(localized: "sessionIndex.day.yesterday", defaultValue: "Yesterday"))
        // Within the last week: a weekday name, not a full date; older gets a
        // date string. We assert shape, not locale-specific words.
        let weekTitle = VaultRecencySections.dayTitle(for: midWeek, now: now, calendar: calendar)
        let olderTitle = VaultRecencySections.dayTitle(for: older, now: now, calendar: calendar)
        #expect(!weekTitle.isEmpty)
        #expect(weekTitle != olderTitle)
        #expect(olderTitle.rangeOfCharacter(from: .decimalDigits) != nil)
        #expect(weekTitle.rangeOfCharacter(from: .decimalDigits) == nil)
    }

    @Test
    func lastActivitySortNewestFirstInsideBucket() {
        let a = makeEntry(id: "a", modified: date(14, hour: 3))
        let b = makeEntry(id: "b", modified: date(14, hour: 9))
        let sections = build([a, b])
        #expect(sections[0].entries.map(\.id) == ["b", "a"])
    }

    @Test
    func createdSortFallsBackToModifiedWhenUnknown() {
        let withCreated = makeEntry(
            id: "a",
            modified: date(14, hour: 5),
            created: date(14, hour: 1)
        )
        let withoutCreated = makeEntry(id: "b", modified: date(14, hour: 4))
        let sections = build([withCreated, withoutCreated], sort: .created)
        // b's fallback created (modified = 04:00) > a's created (01:00).
        #expect(sections[0].entries.map(\.id) == ["b", "a"])
    }

    @Test
    func durationSortTreatsUnknownAsZero() {
        let long = makeEntry(
            id: "long",
            modified: date(14, hour: 10),
            created: date(14, hour: 1)
        )
        let short = makeEntry(
            id: "short",
            modified: date(14, hour: 11),
            created: date(14, hour: 10)
        )
        let unknown = makeEntry(id: "unknown", modified: date(14, hour: 11, month: 8))
        let sections = build([short, unknown, long], sort: .duration)
        #expect(sections[0].entries.map(\.id) == ["long", "short", "unknown"])
    }

    @Test
    func folderSortIsAlphabeticalThenRecency() {
        let alpha = makeEntry(id: "a", cwd: "/Users/dev/alpha", modified: date(14, hour: 1))
        let betaNew = makeEntry(id: "b1", cwd: "/Users/dev/beta", modified: date(14, hour: 9))
        let betaOld = makeEntry(id: "b2", cwd: "/Users/dev/beta", modified: date(14, hour: 2))
        let sections = build([betaOld, alpha, betaNew], sort: .folder)
        #expect(sections[0].entries.map(\.id) == ["a", "b1", "b2"])
    }

    @Test
    func agentFilter() {
        let claude = makeEntry(id: "c", agent: .claude, modified: now)
        let codex = makeEntry(id: "x", agent: .codex, modified: now)
        var filter = VaultSessionFilter()
        filter.agentID = SessionAgent.codex.rawValue
        let sections = build([claude, codex], filter: filter)
        #expect(sections.flatMap(\.entries).map(\.id) == ["x"])
    }

    @Test
    func folderFilterIsExactMatch() {
        let inFolder = makeEntry(id: "a", cwd: "/Users/dev/cmux", modified: now)
        let nested = makeEntry(id: "b", cwd: "/Users/dev/cmux/sub", modified: now)
        var filter = VaultSessionFilter()
        filter.folder = "/Users/dev/cmux"
        let sections = build([inFolder, nested], filter: filter)
        #expect(sections.flatMap(\.entries).map(\.id) == ["a"])
    }

    @Test
    func livenessFilterUsesLiveKeys() {
        let live = makeEntry(id: "live", modified: now)
        let ended = makeEntry(id: "ended", modified: now)
        let liveKeys: Set<String> = [VaultLiveSessionKeys.key(for: live)]

        var liveOnly = VaultSessionFilter()
        liveOnly.liveness = .live
        #expect(build([live, ended], filter: liveOnly, liveKeys: liveKeys)
            .flatMap(\.entries).map(\.id) == ["live"])

        var endedOnly = VaultSessionFilter()
        endedOnly.liveness = .ended
        #expect(build([live, ended], filter: endedOnly, liveKeys: liveKeys)
            .flatMap(\.entries).map(\.id) == ["ended"])
    }

    @Test
    func datePresetFiltersOnModified() {
        let today = makeEntry(id: "t", modified: date(14, hour: 1))
        let lastWeek = makeEntry(id: "w", modified: date(9, hour: 1))
        let lastMonth = makeEntry(id: "m", modified: date(20, hour: 1, month: 7))
        let ancient = makeEntry(id: "old", modified: date(1, hour: 1, month: 1))

        var todayOnly = VaultSessionFilter()
        todayOnly.datePreset = .today
        #expect(build([today, lastWeek, lastMonth, ancient], filter: todayOnly)
            .flatMap(\.entries).map(\.id) == ["t"])

        var week = VaultSessionFilter()
        week.datePreset = .last7Days
        #expect(build([today, lastWeek, lastMonth, ancient], filter: week)
            .flatMap(\.entries).map(\.id) == ["t", "w"])

        var month = VaultSessionFilter()
        month.datePreset = .last30Days
        #expect(Set(build([today, lastWeek, lastMonth, ancient], filter: month)
            .flatMap(\.entries).map(\.id)) == ["t", "w", "m"])
    }

    @Test
    func accessoriesCarryStatusDetailAndCount() {
        let entry = makeEntry(
            id: "a",
            cwd: "/Users/dev/projects/cmux",
            branch: "main",
            modified: now,
            messageCount: 12
        )
        let sections = build([entry], liveKeys: [VaultLiveSessionKeys.key(for: entry)])
        let accessory = sections[0].accessories[entry.id]
        #expect(accessory?.liveStatus == .live)
        #expect(accessory?.detail == "cmux · main")
        #expect(accessory?.messageCount == 12)
        #expect(accessory?.hasSubtitle == true)
    }

    @Test
    func emptyInputProducesNoSections() {
        #expect(build([]).isEmpty)
    }
}
