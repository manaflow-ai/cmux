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
    func catalogHasUniqueIDsAndHidesTheHoldCommandTipWhenHintsAreOff() {
        let all = SidebarTipsCatalog.all
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.allSatisfy { !$0.title.isEmpty && !$0.message.isEmpty && !$0.id.contains(",") })
        #expect(SidebarTipsCatalog.visibleTips(showsModifierHoldHints: true).count == all.count)
        #expect(!SidebarTipsCatalog.visibleTips(showsModifierHoldHints: false).contains { $0.requiresModifierHoldHints })
    }
}
