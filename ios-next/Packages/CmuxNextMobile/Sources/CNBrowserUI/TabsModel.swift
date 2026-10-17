#if os(iOS)
import CNCore
import CNTransport
import Foundation
import Observation
import QuartzCore
import SwiftUI
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
    /// How far a terminal's card image moves up (page points) so its prompt
    /// shows in a card `visibleHeight` points tall below the status strip.
    @ObservationIgnored var terminalCardOffset: ((String, CGFloat) -> CGFloat)?
    /// The same for the terminal's live view (the zoom and the grid).
    @ObservationIgnored var terminalLiveCardOffset: ((String, CGFloat) -> CGFloat)?
    /// Asks for live thumbnails of these terminal ids (the grid is about to show).
    @ObservationIgnored var showTerminalCards: (([String]) -> Void)?
    /// When the host last moved the grid's cards to new slots (a tab or
    /// terminal opened or closed on the Mac), on the media clock. The
    /// user's own closes do not count: a second ✕ during their reflow closes
    /// the card that slid under the finger, as in Safari.
    @ObservationIgnored var gridChangedAt: CFTimeInterval = 0
    /// A card's close button acts only once a host-driven reflow has
    /// stopped: a tap aimed at one card while such a reflow slid another
    /// under the finger closed the wrong tab (re-audit 2, real host).
    var gridAcceptsCloseTaps: Bool { GridTapGuard.accepts(now: CACurrentMediaTime(), changedAt: gridChangedAt) }

    /// The count the grid's bar shows while a close is on its way (nil: the
    /// list's): a ✕ keeps the old count until the reflow's first frame (the
    /// frame before the cards move, as in Safari); a fling shows the new one
    /// from the release tick.
    var countHold: Int?

    /// Set by the screen: zoom out to the grid, then remove `key`'s card
    /// (a terminal that ended on the Mac; "Back to Terminals").
    @ObservationIgnored var backToGridRemoving: ((String) -> Void)?

    /// A terminal that ended on the Mac (its PTY is gone): drop its card.
    /// No `term.close` (there is nothing left to close on the host).
    func removeEndedTerminal(_ key: String, animation: Animation? = nil) {
        guard let id = TabItem.terminalId(fromKey: key) else { return }
        withAnimation(animation) { removeTerminalLocally(key, id: id) }
    }
    /// Holds (true) or resumes (false) the terminal cards' live refresh.
    @ObservationIgnored var pauseTerminalCards: ((Bool) -> Void)?
    /// The open terminal's live view becomes its static card (true when it
    /// had a frame to show); and back to live.
    @ObservationIgnored var terminalShowAsCard: ((String) -> Bool)?
    @ObservationIgnored var terminalShowLive: ((String) -> Void)?
    /// Tells the terminal cards whether the grid is on screen.
    @ObservationIgnored var terminalCardsVisible: ((Bool) -> Void)?

    /// The grid appeared or was covered by a page: hidden cards never render.
    func setGridVisible(_ visible: Bool) {
        terminalCardsVisible?(visible)
    }

    /// The grid started or stopped scrolling: live card refreshes (an
    /// off-screen Ghostty draw, a GPU readback and a grid update each) wait
    /// until it stops, so they do not land in scroll frames.
    func setGridScrolling(_ scrolling: Bool) {
        pauseTerminalCards?(scrolling)
    }

    init(connection: HostConnection, includesTerminals: Bool) {
        browser = BrowserModel(connection: connection)
        self.includesTerminals = includesTerminals
        browser.bringForward = { [weak self] id in
            guard let self, AppSettings.current.browserBringForward else { return false }
            return self.hiddenOnMac(id) != nil
        }
    }

    /// Settings › Browser "Bring tabs forward on Mac automatically"
    /// (`AppPreferences.browserBringForwardKey`; off by default).
    static let bringForwardKey = AppSettings.browserBringForwardKey

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

    /// The grid's cards: pinned items first (Safari's pinned area), then
    /// browser tabs and terminals in grid order.
    var items: [TabItem] {
        let all = allItems
        guard !pins.keys.isEmpty else { return all }
        var byKey: [String: TabItem] = [:]
        for i in all { byKey[i.id] = i }
        return pins.arranged(all.map(\.id)).compactMap { byKey[$0] }
    }

    // MARK: Pinned tabs and Select Tabs (Safari's card menu)

    /// Pinned items, kept on this device per host.
    private(set) var pins = TabPins()
    /// How many of `items` are pinned (they come first).
    var pinnedCount: Int { pins.count(in: allItems.map(\.id)) }
    func isPinned(_ key: String) -> Bool { pins.isPinned(key) }
    private var pinsHost: String { connection.hostId ?? "local" }

    func loadPins() {
        pins = TabPins.load(host: pinsHost)
        #if DEBUG
        // Recordings (scripts/tabs-curves): start from an unpinned grid.
        if ProcessInfo.processInfo.environment["CMUX_NEXT_TABS_RESET_PINS"] == "1" {
            pins = TabPins()
            pins.save(host: pinsHost)
        }
        #endif
    }

    /// Pin Tab / Unpin Tab: the item moves to or from the pinned area.
    func setPinned(_ keys: [String], _ pinned: Bool) {
        let m = BrowserStyle.shared.motion
        withAnimation(m.resolve(m.reflow)) {
            for k in keys { if pinned { pins.pin(k) } else { pins.unpin(k) } }
        }
        pins.save(host: pinsHost)
    }

    /// Select Tabs mode: cards toggle a checkmark; the bar closes, pins or
    /// copies the links of the selected tabs.
    private(set) var selecting = false
    private(set) var selection = TabSelection()

    func beginSelecting(_ key: String? = nil) {
        selection = TabSelection()
        if let key { selection.toggle(key) }
        selecting = true
    }

    func endSelecting() {
        selecting = false
        selection = TabSelection()
    }

    func toggleSelected(_ key: String) { selection.toggle(key) }

    var selectedKeys: [String] { selection.keys(in: items.map(\.id)) }

    /// Close N Tabs: every selected item closes (optimistically, at once).
    func closeSelected(animation: Animation?) {
        let keys = selectedKeys
        endSelecting()
        for k in keys { Task { _ = await closeOptimistic(k, animation: animation) } }
    }

    /// The links of the selected browser tabs, one per line.
    var selectedLinks: String {
        selectedKeys.compactMap { k in browser.tabs.first { $0.id == k }?.url }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

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
        loadPins()
        if let key = activeTerminalKey, item(key) == nil { activeTerminalKey = nil }
    }

    func handle(_ push: HostPush) {
        let before = items.map(\.id)
        defer { if items.map(\.id) != before { gridChangedAt = CACurrentMediaTime() } }
        browser.handle(push)
        if case .browserClosed = push {
            // Same transaction as the browser model's animated removal.
            let m = BrowserStyle.shared.motion
            withAnimation(m.resolve(m.reflow)) { syncOrder() }
        }
        guard includesTerminals else { syncOrder(); return }
        switch push {
        case .terminalUpdated(let t):
            if let i = terminals.firstIndex(where: { $0.id == t.id }) {
                terminals[i] = t
            } else {
                // A terminal opened on the Mac joins the grid animated.
                let m = BrowserStyle.shared.motion
                withAnimation(m.resolve(m.reflow)) {
                    terminals.append(t)
                    syncOrder()
                }
            }
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
            if AppSettings.current.browserBringForward, hiddenOnMac(key) != nil { showOnMac(key) }
            browser.select(key)
        }
    }

    /// Closes a card's tab on the host first; the card leaves the grid (and
    /// the grid reflows, inside `animation`) only once the host confirmed.
    /// Refused: the card stays, a notice says why, and the result is false.
    func closeConfirmed(_ key: String, animation: Animation? = nil) async -> Bool {
        if let id = TabItem.terminalId(fromKey: key) {
            do {
                try await connection.requireClient().closeTerminal(id)
            } catch {
                notice = "Couldn't close the terminal: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                return false
            }
            withAnimation(animation) { removeTerminalLocally(key, id: id) }
            return true
        }
        let wasActive = activeKey == key
        guard await browser.closeConfirmed(key, animation: animation) else { return false }
        withAnimation(animation) {
            syncOrder()
            if wasActive, activeTerminalKey == nil, browser.activeTabId == nil, let first = items.first { select(first.id) }
        }
        return true
    }

    /// Safari's close: the card leaves the grid at once (the grid reflows
    /// inside `animation`, the count updates) while the host closes the tab.
    /// Refused: the card comes back to its slot, selected again if it was,
    /// a notice says why, and the result is false.
    func closeOptimistic(_ key: String, animation: Animation? = nil) async -> Bool {
        let savedOrder = order
        let wasActive = activeKey == key
        if let id = TabItem.terminalId(fromKey: key) {
            guard let index = terminals.firstIndex(where: { $0.id == id }) else { return true }
            let terminal = terminals[index]
            let thumbnail = terminalThumbnails[key]
            withAnimation(animation) { removeTerminalLocally(key, id: id) }
            if countHold == max(1, items.count) { countHold = nil }
            // A terminal that ended on the Mac has nothing left to close there.
            guard terminal.running else { return true }
            do {
                try await connection.requireClient().closeTerminal(id)
                return true
            } catch where TerminalClose.isGone(error) {
                // The host no longer has it (it ended, or is unknown): the
                // card's removal stands.
                return true
            } catch {
                countHold = nil
                withAnimation(animation) {
                    if !terminals.contains(where: { $0.id == id }) { terminals.insert(terminal, at: min(index, terminals.count)) }
                    terminalThumbnails[key] = terminalThumbnails[key] ?? thumbnail
                    restoreOrder(savedOrder)
                }
                if wasActive { select(key) }
                notice = "Couldn't close the terminal: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                return false
            }
        }
        guard let removed = browser.removeOptimistically(key, animation: animation) else { return true }
        withAnimation(animation) {
            syncOrder()
            if wasActive, activeTerminalKey == nil, browser.activeTabId == nil, let first = items.first { select(first.id) }
        }
        if countHold == max(1, items.count) { countHold = nil }
        guard await browser.finishClose(removed, animation: animation) else {
            countHold = nil
            withAnimation(animation) { restoreOrder(savedOrder) }
            if wasActive { select(key) }
            return false
        }
        return true
    }

    /// Long press and drag on the grid: `key` moves to `index` (local grid
    /// order; the host keeps its own).
    func move(_ key: String, to index: Int) {
        var keys = items.map(\.id)
        guard let from = keys.firstIndex(of: key) else { return }
        keys.remove(at: from)
        keys.insert(key, at: max(0, min(index, keys.count)))
        if keys != order { order = keys }
    }

    /// Duplicate Tab: a new browser tab on the same page, placed right after
    /// the original (Safari). Nil when the host refused (notice set).
    @discardableResult
    func duplicate(_ key: String) async -> String? {
        guard let tab = browser.tabs.first(where: { $0.id == key }) else { return nil }
        let wasActive = activeKey
        guard let id = await browser.newTab(url: tab.url, attach: false) else { return nil }
        let m = BrowserStyle.shared.motion
        withAnimation(m.resolve(m.reflow)) {
            syncOrder()
            if let i = items.firstIndex(where: { $0.id == key }) { move(id, to: i + 1) }
        }
        // Safari keeps the grid on the original's selection.
        if let wasActive, wasActive != activeKey { select(wasActive) }
        browser.requestThumbnail(id)
        return id
    }

    /// The order from before an optimistic close, for the items that exist.
    private func restoreOrder(_ saved: [String]) {
        order = saved
        syncOrder()
    }

    private func removeTerminalLocally(_ key: String, id: String) {
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
    }

    /// Fire-and-forget close (menus, Close All): the card stays until the
    /// host confirms.
    func close(_ key: String, animation: Animation? = nil) {
        Task { _ = await closeConfirmed(key, animation: animation) }
    }

    /// New browser tab (start page); `onCreated` gets its key as soon as it exists.
    @discardableResult
    /// Nil when the host refused: the selection is unchanged and a notice
    /// says why (never another tab in its place).
    func newBrowserTab(attach: Bool = true, onCreated: ((String) -> Void)? = nil) async -> String? {
        let id = await browser.newTab(attach: attach, onCreated: { id in
            self.activeTerminalKey = nil
            self.syncOrder()
            onCreated?(id)
        })
        syncOrder()
        return id
    }

    /// New terminal on the Mac, appended at the end and selected.
    @discardableResult
    func newTerminal(onCreated: ((String) -> Void)? = nil) async -> String? {
        guard let client = connection.client else {
            notice = "Couldn't open a terminal: not connected to your Mac."
            return nil
        }
        do {
            let t = try await client.createTerminal(cols: 80, rows: 24)
            if !terminals.contains(where: { $0.id == t.id }) { terminals.append(t) }
            syncOrder()
            let key = TabItem.terminalPrefix + t.id
            onCreated?(key)
            select(key)
            return key
        } catch {
            notice = BrowserModel.createFailureNotice("a terminal", error)
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
        if AppSettings.current.browserBringForward, hiddenOnMac(key) != nil { showOnMac(key) }
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

    /// A card's content anchor: how far its snapshot moves up (page points)
    /// in a card showing `visibleHeight` page points below the strip. A
    /// terminal's card shows its prompt, not its top rows (Tabs QA #8).
    func cardContentOffset(_ key: String, visibleHeight: CGFloat) -> CGFloat {
        guard let id = TabItem.terminalId(fromKey: key) else { return 0 }
        return terminalCardOffset?(id, visibleHeight) ?? 0
    }

    func refreshThumbnails() {
        browser.refreshThumbnails()
        guard includesTerminals else { return }
        showTerminalCards?(terminals.map(\.id))
    }
}
#endif
