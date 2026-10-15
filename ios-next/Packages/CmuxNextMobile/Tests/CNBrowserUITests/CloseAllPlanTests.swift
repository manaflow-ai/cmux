@testable import CNBrowserUI
import Testing

struct CloseAllPlanTests {
    /// Only browser tabs: Safari's own wording.
    @Test func tabsOnlyUseSafarisWording() {
        let plan = CloseAllPlan(tabs: 3, terminals: 0)
        #expect(plan.title == "Close All 3 Tabs?")
        #expect(plan.closeAllLabel == "Close All 3 Tabs")
        #expect(plan.message == nil)
        #expect(plan.closeTabsOnlyLabel == nil)
        #expect(CloseAllPlan(tabs: 1, terminals: 0).closeAllLabel == "Close Tab")
    }

    /// Terminals are named, their shells' end is spelled out, and the
    /// browser tabs can be closed on their own.
    @Test func terminalsAreNamedAndCanBeKept() {
        let plan = CloseAllPlan(tabs: 3, terminals: 2)
        #expect(plan.title == "Close 3 Tabs and 2 Terminals?")
        #expect(plan.closeAllLabel == "Close 3 Tabs and 2 Terminals")
        #expect(plan.message == "Closing the terminals ends their shells on your Mac. Anything running in them stops.")
        #expect(plan.closeTabsOnlyLabel == "Close 3 Tabs, Keep Terminals")
        let one = CloseAllPlan(tabs: 1, terminals: 1)
        #expect(one.title == "Close 1 Tab and 1 Terminal?")
        #expect(one.message == "Closing the terminal ends its shell on your Mac. Anything running in it stops.")
        #expect(CloseAllPlan(tabs: 0, terminals: 2).closeTabsOnlyLabel == nil)
        #expect(CloseAllPlan(tabs: 0, terminals: 2).closeAllLabel == "Close All 2 Terminals")
    }
}
