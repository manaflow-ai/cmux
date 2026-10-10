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

    static let terminalPrefix = "term:"

    /// Grid key. Browser tabs keep their tab id (the browser screen's own
    /// keys); terminals are prefixed so the two id spaces never collide.
    var id: String {
        switch self {
        case .browser(let t): t.id
        case .terminal(let t): Self.terminalPrefix + t.id
        }
    }

    var isTerminal: Bool { if case .terminal = self { true } else { false } }
    var browserTab: BrowserTab? { if case .browser(let t) = self { t } else { nil } }
    var terminal: Terminal? { if case .terminal(let t) = self { t } else { nil } }

    var title: String {
        switch self {
        case .browser(let t): t.title.isEmpty ? t.displayHost : t.title
        case .terminal(let t): t.title.isEmpty ? "Terminal" : t.title
        }
    }

    static func terminalId(fromKey key: String) -> String? {
        key.hasPrefix(terminalPrefix) ? String(key.dropFirst(terminalPrefix.count)) : nil
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
    /// The selected terminal's key; nil while a browser tab is selected.
    private(set) var activeTerminalKey: String?
    private(set) var terminalThumbnails: [String: UIImage] = [:]
    var notice: String? {
        get { browser.notice }
        set { browser.notice = newValue }
    }

    @ObservationIgnored var connection: HostConnection { browser.connection }
    /// Renders terminal card snapshots (CNTerminalUI); set by the tabs root.
    @ObservationIgnored var terminalSnapshot: ((String) async -> UIImage?)?

    init(connection: HostConnection, includesTerminals: Bool) {
        browser = BrowserModel(connection: connection)
        self.includesTerminals = includesTerminals
    }

    // MARK: Items

    /// Which kinds the grid shows (the tabs screen's All · Browser · Terminals).
    enum Filter: String, CaseIterable, Sendable {
        case all, browser, terminals
        var title: String {
            switch self {
            case .all: "All"
            case .browser: "Browser"
            case .terminals: "Terminals"
            }
        }
    }

    private static let filterKey = "cmuxNext.tabs.filter"
    /// Remembered per device.
    var filter: Filter = Filter(rawValue: UserDefaults.standard.string(forKey: TabsModel.filterKey) ?? "") ?? .all {
        didSet { UserDefaults.standard.set(filter.rawValue, forKey: Self.filterKey) }
    }

    /// The grid's cards: every item, narrowed by `filter`.
    var items: [TabItem] {
        guard includesTerminals, filter != .all else { return allItems }
        return allItems.filter { $0.isTerminal == (filter == .terminals) }
    }

    func count(_ f: Filter) -> Int {
        switch f {
        case .all: allItems.count
        case .browser: browser.tabs.count
        case .terminals: includesTerminals ? terminals.count : 0
        }
    }

    /// Every item in grid order, ignoring the filter.
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
    var activeItem: TabItem? { allItems.first { $0.id == activeKey } }
    var activeIndex: Int? { items.firstIndex { $0.id == activeKey } }
    var activeTerminal: Terminal? { activeItem?.terminal }
    var loaded: Bool { browser.loaded }

    func item(_ key: String) -> TabItem? { allItems.first { $0.id == key } }

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
        if let key = activeTerminalKey, item(key) == nil { activeTerminalKey = nil }
    }

    // MARK: Selection

    /// Shows `key`. Selecting a terminal stops the browser stream; selecting
    /// a browser tab attaches it again.
    func select(_ key: String) {
        if TabItem.terminalId(fromKey: key) != nil {
            guard activeTerminalKey != key else { return }
            activeTerminalKey = key
            browser.detachAll()
        } else {
            activeTerminalKey = nil
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
        if TabItem.terminalId(fromKey: key) != nil { select(key) } else { activeTerminalKey = nil; browser.open(tabId: key) }
    }

    // MARK: Cards

    func requestThumbnail(_ key: String) {
        guard TabItem.terminalId(fromKey: key) == nil else { return }
        browser.requestThumbnail(key)
    }

    func showsStartPage(_ key: String?) -> Bool {
        guard let key else { return true }
        if TabItem.terminalId(fromKey: key) != nil { return false }
        return browser.showsStartPage(key)
    }

    func cardImage(_ key: String) -> UIImage? {
        if TabItem.terminalId(fromKey: key) != nil { return terminalThumbnails[key] }
        return browser.cardImage(key)
    }

    func refreshThumbnails() {
        browser.refreshThumbnails()
        guard includesTerminals, let snapshot = terminalSnapshot else { return }
        for t in terminals {
            let key = TabItem.terminalPrefix + t.id
            Task {
                if let image = await snapshot(t.id) { terminalThumbnails[key] = image }
            }
        }
    }
}
#endif
