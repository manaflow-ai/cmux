/// Safari's "Close All Tabs" confirmation, extended to terminals: Safari asks
/// "Close All N Tabs?" before closing anything. A terminal in the grid is a
/// tab too, but closing it ends its shell on the Mac, so the confirmation
/// names terminals separately and offers to close only the browser tabs.
struct CloseAllPlan: Equatable {
    var tabs: Int
    var terminals: Int

    var total: Int { tabs + terminals }
    var isEmpty: Bool { total == 0 }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }

    /// The sheet's title, as Safari words it when there are only tabs.
    var title: String {
        if terminals == 0 { return tabs == 1 ? "Close 1 Tab?" : "Close All \(tabs) Tabs?" }
        if tabs == 0 { return terminals == 1 ? "Close 1 Terminal?" : "Close All \(terminals) Terminals?" }
        return "Close \(Self.count(tabs, "Tab", "Tabs")) and \(Self.count(terminals, "Terminal", "Terminals"))?"
    }

    /// What closing terminals does (nil when none would close).
    var message: String? {
        guard terminals > 0 else { return nil }
        let one = terminals == 1
        return "Closing \(one ? "the terminal" : "the terminals") ends \(one ? "its shell" : "their shells") on your Mac. "
            + "Anything running in \(one ? "it" : "them") stops."
    }

    /// The destructive button that closes everything.
    var closeAllLabel: String {
        if terminals == 0 { return tabs == 1 ? "Close Tab" : "Close All \(tabs) Tabs" }
        if tabs == 0 { return terminals == 1 ? "Close Terminal" : "Close All \(terminals) Terminals" }
        return "Close \(Self.count(tabs, "Tab", "Tabs")) and \(Self.count(terminals, "Terminal", "Terminals"))"
    }

    /// A second choice that keeps the terminals, when there are both kinds.
    var closeTabsOnlyLabel: String? {
        guard tabs > 0, terminals > 0 else { return nil }
        return tabs == 1 ? "Close 1 Tab, Keep Terminals" : "Close \(tabs) Tabs, Keep Terminals"
    }
}
