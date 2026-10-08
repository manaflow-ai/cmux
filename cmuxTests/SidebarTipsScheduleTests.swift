import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SidebarTipsScheduleTests {
    @Test
    func legacyOptOutIsPreservedWithoutRemovingManualAccess() {
        let progress = SidebarTipsStorage.progress(
            currentTipID: "commandPalette", seenTipIDs: "commandPalette", lastOpenedDay: "2026-10-07",
            automaticTipsDisabled: true
        )
        #expect(progress.automaticTipsDisabled)
        #expect(progress.lastOpenedAt == nil)
        #expect(progress.currentTipID == "commandPalette")
    }

    @Test
    func storageRoundTripsSeenTipsAndTheReminderTimestamp() {
        let progress = SidebarTipsStorage.progress(
            currentTipID: "splitPanes", seenTipIDs: "splitPanes,commandPalette", lastOpenedDay: "2026-10-07",
            automaticTipsDisabled: true, lastOpenedAt: 1_791_417_600
        )
        #expect(SidebarTipsStorage.encodedSeenTipIDs(progress.seenTipIDs) == "commandPalette,splitPanes")
        #expect(progress.lastOpenedAt?.timeIntervalSince1970 == 1_791_417_600)
        #expect(progress.automaticTipsDisabled)
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
