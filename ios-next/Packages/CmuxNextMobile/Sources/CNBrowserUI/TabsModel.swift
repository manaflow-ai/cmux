#if os(iOS)
import CNCore
import CNTransport
import Foundation
import Observation
import UIKit

/// One card in the tab grid: a browser tab or a terminal on the Mac.
enum TabItem: Identifiable, Hashable {
    case browser(BrowserTab)
    case terminal(Terminal)
    /// A Mac tab the phone cannot open live (a CEF browser pane, a
    /// conversation, an unknown kind): shown as a placeholder.
    case macOnly(LayoutTab)

    static let terminalPrefix = "term:"
    static let macPrefix = "mac:"

    /// Grid key. Browser tabs keep their tab id (the browser screen's own
    /// keys); the others are prefixed so the id spaces never collide.
    var id: String {
        switch self {
        case .browser(let t): t.id
        case .terminal(let t): Self.terminalPrefix + t.id
        case .macOnly(let t): Self.macPrefix + t.id
        }
    }

    var isTerminal: Bool { if case .terminal = self { true } else { false } }
    var isBrowser: Bool { if case .browser = self { true } else { false } }
    var browserTab: BrowserTab? { if case .browser(let t) = self { t } else { nil } }
    var terminal: Terminal? { if case .terminal(let t) = self { t } else { nil } }

    var title: String {
        switch self {
        case .browser(let t): t.title.isEmpty ? t.displayHost : t.title
        case .terminal(let t): t.title.isEmpty ? "Terminal" : t.title
        case .macOnly(let t): t.title.isEmpty ? (t.url ?? "Tab") : t.title
        }
    }

    var symbol: String {
        switch self {
        case .browser: "globe"
        case .terminal: "apple.terminal"
        case .macOnly(let t): t.kind == .browser ? "globe" : "macwindow"
        }
    }

    static func terminalId(fromKey key: String) -> String? {
        key.hasPrefix(terminalPrefix) ? String(key.dropFirst(terminalPrefix.count)) : nil
    }

    static func isBrowserKey(_ key: String) -> Bool {
        !key.hasPrefix(terminalPrefix) && !key.hasPrefix(macPrefix)
    }
}

/// The grid's items in one list. Order is creation order with new items at
/// the end (Safari's grid): the browser tabs as the host lists them, then
/// terminals by creation time, then everything created later appended.
/// The browser screen uses the same model with terminals turned off.
@MainActor
@Observable
final class TabsModel {
    let browser: BrowserModel
    let includesTerminals: Bool
    private(set) var terminals: [Terminal] = []
    /// Item keys in grid order.
    private(set) var order: [String] = []
    /// The selected non-browser item's key (terminal, Mac-only);
    /// nil while a browser tab is selected.
    private(set) var activeTerminalKey: String?
    /// The Mac's workspaces and panes (`layout.v1`); nil without it.
    private(set) var layout: MacLayout?
    /// Whether the host serves the Mac's own browser tabs (`browser.mac.v1`).
    var browserAccess: BrowserMacStatus?
    private(set) var terminalThumbnails: [String: UIImage] = [:]
    var notice: String? {
        get { browser.notice }
        set { browser.notice = newValue }
    }

    @ObservationIgnored var connection: HostConnection { browser.connection }
    /// Terminal card images (CNTerminalUI's live thumbnails); set by the tabs root.
    @ObservationIgnored var terminalImage: ((String) -> UIImage?)?
    /// Asks for live thumbnails of these terminal ids (the grid is about to show).
    @ObservationIgnored var showTerminalCards: (([String]) -> Void)?

    init(connection: HostConnection, includesTerminals: Bool) {
        browser = BrowserModel(connection: connection)
        self.includesTerminals = includesTerminals
        browser.bringForward = { [weak self] id in
            guard let self, UserDefaults.standard.bool(forKey: Self.bringForwardKey) else { return false }
            return self.hiddenOnMac(id) != nil
        }
    }

    /// Settings › Browser "Bring tabs forward on Mac automatically"
    /// (`AppPreferences.browserBringForwardKey`; off by default).
    static let bringForwardKey = "cmuxNext.browser.bringForward"

    /// The Mac browser tab behind `key` when the Mac is not showing it (its
    /// pane shows another tab, or its workspace is in the background): it
    /// sends no frames until shown.
    func hiddenOnMac(_ key: String) -> (paneId: String, tab: LayoutTab)? {
        guard TabItem.isBrowserKey(key) else { return nil }
        for pane in layout?.workspaces.flatMap(\.panes) ?? [] {
            if let t = pane.tabs.first(where: { $0.kind == .browser && $0.refId == key && $0.visibleOnMac == false }) { return (pane.id, t) }
        }
        return nil
    }

    /// "Show on Mac": selects the tab in its Mac pane so it renders.
    func showOnMac(_ key: String) {
        guard let hidden = hiddenOnMac(key) else { return }
        focus(paneId: hidden.paneId, tab: hidden.tab)
    }

    // MARK: Items

    /// The grid's cards: browser tabs and terminals in creation order.
    var items: [TabItem] { allItems }

    /// Browser tabs and terminals in grid order.
    var allItems: [TabItem] {
        var byKey: [String: TabItem] = [:]
        for t in browser.tabs { byKey[t.id] = .browser(t) }
        if includesTerminals { for t in terminals { byKey[TabItem.terminalPrefix + t.id] = .terminal(t) } }
        var out = order.compactMap { byKey.removeValue(forKey: $0) }
        // Items the order has not seen yet (events between syncs) go last.
        out += browser.tabs.compactMap { byKey.removeValue(forKey: $0.id) }
        out += terminals.compactMap { byKey.removeValue(forKey: TabItem.terminalPrefix + $0.id) }
        return out
    }

    var activeKey: String? { activeTerminalKey ?? browser.activeTabId }
    var activeItem: TabItem? { activeKey.flatMap(item) }
    var activeIndex: Int? { items.firstIndex { $0.id == activeKey } }
    var activeTerminal: Terminal? { activeItem?.terminal }
    var loaded: Bool { browser.loaded }

    func item(_ key: String) -> TabItem? {
        if let i = allItems.first(where: { $0.id == key }) { return i }
        for ws in layout?.workspaces ?? [] { for p in ws.panes { for t in p.tabs where itemKey(t) == key { return item(for: t) } } }
        return nil
    }

    // MARK: Mac layout

    /// The item a layout tab shows.
    func item(for tab: LayoutTab) -> TabItem {
        switch tab.kind {
        case .terminal:
            if let id = tab.refId, let t = terminals.first(where: { $0.id == id }) { return .terminal(t) }
        case .browser:
            if tab.streamable, let id = tab.refId, let t = browser.tabs.first(where: { $0.id == id }) { return .browser(t) }
        default:
            break
        }
        return .macOnly(tab)
    }

    func itemKey(_ tab: LayoutTab) -> String { item(for: tab).id }

    /// A new layout snapshot. An open Mac-only tab that became live (browser
    /// access turned on) switches to its live page.
    func applyLayout(_ l: MacLayout) {
        layout = l
        promoteMacTab()
    }

    private func promoteMacTab() {
        guard let l = layout, let key = activeTerminalKey, key.hasPrefix(TabItem.macPrefix) else { return }
        let tabId = String(key.dropFirst(TabItem.macPrefix.count))
        if let tab = l.workspaces.flatMap(\.panes).flatMap(\.tabs).first(where: { $0.id == tabId }) {
            let now = itemKey(tab)
            if now != key { select(now) }
        } else {
            activeTerminalKey = nil
        }
    }

    /// Focuses `tab` in its pane on the Mac (and here at once).
    func focus(paneId: String, tab: LayoutTab) {
        if var l = layout {
            for w in l.workspaces.indices {
                for p in l.workspaces[w].panes.indices where l.workspaces[w].panes[p].id == paneId {
                    l.workspaces[w].panes[p].focusedTabId = tab.id
                    for t in l.workspaces[w].panes[p].tabs.indices {
                        let picked = l.workspaces[w].panes[p].tabs[t].id == tab.id
                        l.workspaces[w].panes[p].tabs[t].focused = picked
                        // The Mac shows the picked tab now (its pane and workspace come forward).
                        if picked, l.workspaces[w].panes[p].tabs[t].visibleOnMac != nil { l.workspaces[w].panes[p].tabs[t].visibleOnMac = true }
                    }
                }
            }
            layout = l
        }
        Task { try? await connection.client?.focusLayoutTab(paneId: paneId, tabId: tab.id) }
    }

    /// Appends keys the order has not seen, keeping the existing order.
    private func syncOrder(initial: Bool = false) {
        var keys = order.filter { key in
            if let id = TabItem.terminalId(fromKey: key) { return terminals.contains { $0.id == id } }
            return browser.tabs.contains { $0.id == key }
        }
        for t in browser.tabs where !keys.contains(t.id) { keys.append(t.id) }
        if includesTerminals {
            for t in terminals.sorted(by: { $0.createdAt < $1.createdAt }) where !keys.contains(TabItem.terminalPrefix + t.id) {
                keys.append(TabItem.terminalPrefix + t.id)
            }
        }
        if keys != order { order = keys }
    }

    // MARK: Loading and events

    func reload() async {
        await browser.reload()
        if includesTerminals, let client = connection.client {
            if let list = try? await client.listTerminals() { terminals = list }
            let caps = connection.hostInfo
            if caps?.supports(.layout) ?? false { layout = try? await client.layout() }
            if caps?.supports(.browserMac) ?? false { browserAccess = try? await client.browserMacStatus() }
        }
        syncOrder(initial: true)
        if let key = activeTerminalKey, item(key) == nil { activeTerminalKey = nil }
    }

    func handle(_ push: HostPush) {
        browser.handle(push)
        guard includesTerminals else { syncOrder(); return }
        switch push {
        case .terminalUpdated(let t):
            if let i = terminals.firstIndex(where: { $0.id == t.id }) { terminals[i] = t } else { terminals.append(t) }
        case .terminalExited(let id, _):
            if let i = terminals.firstIndex(where: { $0.id == id }) { terminals[i].running = false }
        default:
            break
        }
        syncOrder()
        promoteMacTab()
        if let key = activeTerminalKey, item(key) == nil { activeTerminalKey = nil }
    }

    // MARK: Selection

    /// Shows `key`. Selecting a terminal stops the browser stream; selecting
    /// a browser tab attaches it again.
    func select(_ key: String) {
        if !TabItem.isBrowserKey(key) {
            guard activeTerminalKey != key else { return }
            activeTerminalKey = key
            browser.detachAll()
        } else {
            activeTerminalKey = nil
            // "Bring tabs forward on Mac automatically": a tab the Mac is
            // not drawing is shown there first (no "Show on Mac" tap).
            if UserDefaults.standard.bool(forKey: Self.bringForwardKey), hiddenOnMac(key) != nil { showOnMac(key) }
            browser.select(key)
        }
    }

    func close(_ key: String) {
        if let id = TabItem.terminalId(fromKey: key) {
            let wasActive = activeTerminalKey == key
            let index = items.firstIndex { $0.id == key } ?? 0
            terminals.removeAll { $0.id == id }
            terminalThumbnails[key] = nil
            syncOrder()
            if wasActive {
                activeTerminalKey = nil
                let rest = items
                if !rest.isEmpty { select(rest[min(index, rest.count - 1)].id) }
            }
            Task {
                do { try await connection.requireClient().closeTerminal(id) } catch {
                    notice = "Couldn't close the terminal: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                    if let list = try? await connection.client?.listTerminals() { terminals = list; syncOrder() }
                }
            }
        } else {
            let wasActive = activeKey == key
            browser.close(key)
            syncOrder()
            if wasActive, activeTerminalKey == nil, browser.activeTabId == nil, let first = items.first { select(first.id) }
        }
    }

    /// New browser tab (start page); `onCreated` gets its key as soon as it exists.
    @discardableResult
    func newBrowserTab(onCreated: ((String) -> Void)? = nil) async -> String? {
        activeTerminalKey = nil
        let id = await browser.newTab(onCreated: { id in
            self.syncOrder()
            onCreated?(id)
        })
        syncOrder()
        return id
    }

    /// New terminal on the Mac, appended at the end and selected.
    @discardableResult
    func newTerminal(onCreated: ((String) -> Void)? = nil) async -> String? {
        guard let client = connection.client else { return nil }
        do {
            let t = try await client.createTerminal(cols: 80, rows: 24)
            if !terminals.contains(where: { $0.id == t.id }) { terminals.append(t) }
            syncOrder()
            let key = TabItem.terminalPrefix + t.id
            onCreated?(key)
            select(key)
            return key
        } catch {
            notice = "Couldn't open a terminal: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            return nil
        }
    }

    func rename(terminalKey key: String, to title: String) {
        guard let id = TabItem.terminalId(fromKey: key) else { return }
        if let i = terminals.firstIndex(where: { $0.id == id }) { terminals[i].title = title }
        Task { try? await connection.client?.renameTerminal(id, title: title) }
    }

    /// A drawer row asked for `key` (browser tab id, or a terminal key).
    func open(key: String) {
        if !TabItem.isBrowserKey(key) { select(key); return }
        activeTerminalKey = nil
        if UserDefaults.standard.bool(forKey: Self.bringForwardKey), hiddenOnMac(key) != nil { showOnMac(key) }
        browser.open(tabId: key)
    }

    // MARK: Cards

    func requestThumbnail(_ key: String) {
        guard TabItem.isBrowserKey(key) else { return }
        browser.requestThumbnail(key)
    }

    func showsStartPage(_ key: String?) -> Bool {
        guard let key else { return true }
        if !TabItem.isBrowserKey(key) { return false }
        return browser.showsStartPage(key)
    }

    func cardImage(_ key: String) -> UIImage? {
        if let id = TabItem.terminalId(fromKey: key) { return terminalImage?(id) ?? terminalThumbnails[key] }
        if !TabItem.isBrowserKey(key) { return nil }
        return browser.cardImage(key)
    }

    func refreshThumbnails() {
        browser.refreshThumbnails()
        guard includesTerminals else { return }
        showTerminalCards?(terminals.map(\.id))
    }
}
#endif
