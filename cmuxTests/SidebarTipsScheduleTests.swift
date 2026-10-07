import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SidebarTipsScheduleTests {
    private let tipIDs = ["a", "b", "c"]

    @Test
    func firstLaunchMarksANewTipAndOpeningShowsTheFirstOne() {
        let fresh = SidebarTipsProgress()
        #expect(SidebarTipsSchedule.showsNewTipIndicator(fresh, tipIDs: tipIDs, today: "2026-10-07"))

        let opened = SidebarTipsSchedule.opened(fresh, tipIDs: tipIDs, today: "2026-10-07")
        #expect(opened.currentTipID == "a")
        #expect(opened.seenTipIDs == ["a"])
        #expect(!SidebarTipsSchedule.showsNewTipIndicator(opened, tipIDs: tipIDs, today: "2026-10-07"))
    }

    @Test
    func reopeningTheSameDayKeepsTheTip() {
        let opened = SidebarTipsSchedule.opened(SidebarTipsProgress(), tipIDs: tipIDs, today: "2026-10-07")
        let reopened = SidebarTipsSchedule.opened(opened, tipIDs: tipIDs, today: "2026-10-07")
        #expect(reopened == opened)
    }

    @Test
    func aNewDayMarksAndShowsTheNextUnseenTip() {
        let dayOne = SidebarTipsSchedule.opened(SidebarTipsProgress(), tipIDs: tipIDs, today: "2026-10-07")
        #expect(SidebarTipsSchedule.showsNewTipIndicator(dayOne, tipIDs: tipIDs, today: "2026-10-08"))

        let dayTwo = SidebarTipsSchedule.opened(dayOne, tipIDs: tipIDs, today: "2026-10-08")
        #expect(dayTwo.currentTipID == "b")
        #expect(dayTwo.seenTipIDs == ["a", "b"])
    }

    @Test
    func pagingMarksTipsSeenAndTheNextDaySkipsThem() {
        var progress = SidebarTipsSchedule.opened(SidebarTipsProgress(), tipIDs: tipIDs, today: "2026-10-07")
        progress = SidebarTipsSchedule.selected(progress, tipID: "b")
        #expect(progress.currentTipID == "b")
        #expect(progress.seenTipIDs == ["a", "b"])

        let nextDay = SidebarTipsSchedule.opened(progress, tipIDs: tipIDs, today: "2026-10-08")
        #expect(nextDay.currentTipID == "c")
    }

    @Test
    func onceEveryTipIsSeenTheIndicatorStaysOff() {
        let progress = SidebarTipsProgress(currentTipID: "c", seenTipIDs: ["a", "b", "c"], lastOpenedDay: "2026-10-07")
        #expect(!SidebarTipsSchedule.showsNewTipIndicator(progress, tipIDs: tipIDs, today: "2026-10-20"))

        let opened = SidebarTipsSchedule.opened(progress, tipIDs: tipIDs, today: "2026-10-20")
        #expect(opened.currentTipID == "a")
    }

    @Test
    func aTipThatIsNoLongerOfferedFallsBackToTheFirstUnseen() {
        let progress = SidebarTipsProgress(currentTipID: "gone", seenTipIDs: ["a"], lastOpenedDay: "2026-10-07")
        let opened = SidebarTipsSchedule.opened(progress, tipIDs: tipIDs, today: "2026-10-07")
        #expect(opened.currentTipID == "b")
    }

    @Test
    func storageRoundTripsProgress() {
        let progress = SidebarTipsProgress(currentTipID: "b", seenTipIDs: ["a", "b"], lastOpenedDay: "2026-10-07")
        let decoded = SidebarTipsStorage.progress(
            currentTipID: progress.currentTipID ?? "",
            seenTipIDs: SidebarTipsStorage.encodedSeenTipIDs(progress.seenTipIDs),
            lastOpenedDay: progress.lastOpenedDay ?? ""
        )
        #expect(decoded == progress)
        #expect(SidebarTipsStorage.progress(currentTipID: "", seenTipIDs: "", lastOpenedDay: "") == SidebarTipsProgress())
    }

    @Test
    func dayKeyUsesTheGivenCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Auckland"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 23, minute: 59)))
        #expect(SidebarTipsSchedule.dayKey(for: date, calendar: calendar) == "2026-01-05")
    }

    @Test
    func catalogHasUniqueIDsAndHidesTheHoldCommandTipWhenHintsAreOff() {
        let all = SidebarTipsCatalog.all
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.allSatisfy { !$0.title.isEmpty && !$0.message.isEmpty && !$0.id.contains(",") })
        #expect(SidebarTipsCatalog.visibleTips(showsModifierHoldHints: true).count == all.count)
        #expect(!SidebarTipsCatalog.visibleTips(showsModifierHoldHints: false).contains { $0.requiresModifierHoldHints })
    }
}
