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
    func theDotShowsUntilTheFirstOpenAndOpeningShowsTheFirstTip() {
        // What the footer reads from never-written defaults (the @AppStorage defaults).
        let fresh = SidebarTipsStorage.progress(currentTipID: "", seenTipIDs: "", lastOpenedDay: "")
        #expect(fresh == SidebarTipsProgress())
        #expect(SidebarTipsSchedule.showsButton(fresh))
        #expect(SidebarTipsSchedule.showsUnopenedIndicator(fresh))

        let opened = SidebarTipsSchedule.opened(fresh, tipIDs: tipIDs, today: "2026-10-07")
        #expect(opened.currentTipID == "a")
        #expect(opened.seenTipIDs == ["a"])
        #expect(!SidebarTipsSchedule.showsUnopenedIndicator(opened))
    }

    @Test
    func theDotNeverComesBackOnLaterDaysEvenWithUnseenTips() {
        let opened = SidebarTipsSchedule.opened(SidebarTipsProgress(), tipIDs: tipIDs, today: "2026-10-07")
        let nextDay = SidebarTipsSchedule.opened(opened, tipIDs: tipIDs, today: "2026-10-08")
        #expect(nextDay.seenTipIDs != Set(tipIDs))
        #expect(!SidebarTipsSchedule.showsUnopenedIndicator(opened))
        #expect(!SidebarTipsSchedule.showsUnopenedIndicator(nextDay))
    }

    @Test
    func hidingRemovesTheButtonAndShowingItAgainKeepsTheDotOff() {
        let opened = SidebarTipsSchedule.opened(SidebarTipsProgress(), tipIDs: tipIDs, today: "2026-10-07")
        var hidden = opened
        hidden.isHidden = true
        #expect(!SidebarTipsSchedule.showsButton(hidden))
        #expect(!SidebarTipsSchedule.showsUnopenedIndicator(hidden))
        #expect(!SidebarTipsSchedule.showsUnopenedIndicator(SidebarTipsProgress(isHidden: true)))

        var restored = hidden
        restored.isHidden = false
        #expect(SidebarTipsSchedule.showsButton(restored))
        #expect(!SidebarTipsSchedule.showsUnopenedIndicator(restored))
        #expect(restored.currentTipID == opened.currentTipID)
    }

    @Test
    func reopeningTheSameDayKeepsTheTip() {
        let opened = SidebarTipsSchedule.opened(SidebarTipsProgress(), tipIDs: tipIDs, today: "2026-10-07")
        let reopened = SidebarTipsSchedule.opened(opened, tipIDs: tipIDs, today: "2026-10-07")
        #expect(reopened == opened)
    }

    @Test
    func aNewDayOpensOnTheNextUnseenTip() {
        let dayOne = SidebarTipsSchedule.opened(SidebarTipsProgress(), tipIDs: tipIDs, today: "2026-10-07")
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
    func onceEveryTipIsSeenANewDayWrapsToTheNextTip() {
        let progress = SidebarTipsProgress(currentTipID: "c", seenTipIDs: ["a", "b", "c"], lastOpenedDay: "2026-10-07")
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
        let progress = SidebarTipsProgress(
            currentTipID: "b",
            seenTipIDs: ["a", "b"],
            lastOpenedDay: "2026-10-07",
            isHidden: true
        )
        let decoded = SidebarTipsStorage.progress(
            currentTipID: progress.currentTipID ?? "",
            seenTipIDs: SidebarTipsStorage.encodedSeenTipIDs(progress.seenTipIDs),
            lastOpenedDay: progress.lastOpenedDay ?? "",
            isHidden: progress.isHidden
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
