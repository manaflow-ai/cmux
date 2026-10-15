import Foundation

public struct BrowserTab: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var url: String
    public var title: String
    public var loading: Bool
    /// 0...1
    public var progress: Double
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var faviconUrl: String?
    public var active: Bool

    public init(id: String, url: String, title: String, loading: Bool = false, progress: Double = 1, canGoBack: Bool = false,
                canGoForward: Bool = false, faviconUrl: String? = nil, active: Bool = false) {
        self.id = id; self.url = url; self.title = title; self.loading = loading; self.progress = progress
        self.canGoBack = canGoBack; self.canGoForward = canGoForward; self.faviconUrl = faviconUrl; self.active = active
    }
}

public struct BrowserTabList: Codable, Sendable, Hashable { public var tabs: [BrowserTab]; public init(tabs: [BrowserTab]) { self.tabs = tabs } }
public struct BrowserTabResult: Codable, Sendable, Hashable { public var tab: BrowserTab; public init(tab: BrowserTab) { self.tab = tab } }
public struct BrowserTabRef: Codable, Sendable, Hashable { public var tabId: String; public init(tabId: String) { self.tabId = tabId } }
public struct BrowserCreateParams: Codable, Sendable, Hashable { public var url: String?; public init(url: String? = nil) { self.url = url } }

public struct BrowserAttachParams: Codable, Sendable, Hashable {
    public var tabId: String
    /// CSS pixels.
    public var width: Int
    public var height: Int
    public var scale: Double
    public var mobile: Bool
    /// Ask for the extended frame header with scroll offsets (PROTOCOL.md §3).
    /// Hosts that predate it ignore the field and send plain frames.
    public var frameMeta: Bool?
    /// The user picked Request Mobile/Desktop Website: reload the page so it
    /// loads with the new user agent (otherwise it applies on the next navigation).
    public var reloadForMode: Bool?
    /// A Mac tab the Mac is not showing: show it there first (the opt-in
    /// "Bring tabs forward on Mac automatically"; `browser.mac.v1`).
    public var bringForward: Bool?
    public init(tabId: String, width: Int, height: Int, scale: Double, mobile: Bool = true, frameMeta: Bool? = nil,
                reloadForMode: Bool? = nil, bringForward: Bool? = nil) {
        self.tabId = tabId; self.width = width; self.height = height; self.scale = scale; self.mobile = mobile
        self.frameMeta = frameMeta; self.reloadForMode = reloadForMode; self.bringForward = bringForward
    }
}

public struct BrowserAttachResult: Codable, Sendable, Hashable {
    public var streamId: UInt32; public var tab: BrowserTab
    public init(streamId: UInt32, tab: BrowserTab) { self.streamId = streamId; self.tab = tab }
}

public struct BrowserViewportParams: Codable, Sendable, Hashable {
    public var tabId: String; public var width: Int; public var height: Int; public var scale: Double
    public init(tabId: String, width: Int, height: Int, scale: Double) { self.tabId = tabId; self.width = width; self.height = height; self.scale = scale }
}

public struct BrowserAckParams: Codable, Sendable, Hashable {
    public var streamId: UInt32; public var seq: UInt32
    public init(streamId: UInt32, seq: UInt32) { self.streamId = streamId; self.seq = seq }
}

public struct BrowserNavigateParams: Codable, Sendable, Hashable {
    public var tabId: String; public var url: String
    public init(tabId: String, url: String) { self.tabId = tabId; self.url = url }
}

public enum PointerEventType: String, Codable, Sendable { case down, up, move }
public enum PointerButton: String, Codable, Sendable { case left, none }

public struct BrowserPointerParams: Codable, Sendable, Hashable {
    public var tabId: String; public var type: PointerEventType; public var x: Double; public var y: Double
    public var button: PointerButton; public var clickCount: Int
    public init(tabId: String, type: PointerEventType, x: Double, y: Double, button: PointerButton = .left, clickCount: Int = 1) {
        self.tabId = tabId; self.type = type; self.x = x; self.y = y; self.button = button; self.clickCount = clickCount
    }
}

public enum TouchEventType: String, Codable, Sendable { case start, move, end, cancel }

public struct TouchPoint: Codable, Sendable, Hashable {
    public var x: Double; public var y: Double; public var id: Int
    public init(x: Double, y: Double, id: Int) { self.x = x; self.y = y; self.id = id }
}

public struct BrowserTouchParams: Codable, Sendable, Hashable {
    public var tabId: String; public var type: TouchEventType; public var points: [TouchPoint]
    public init(tabId: String, type: TouchEventType, points: [TouchPoint]) { self.tabId = tabId; self.type = type; self.points = points }
}

public struct BrowserScrollParams: Codable, Sendable, Hashable {
    public var tabId: String; public var x: Double; public var y: Double; public var dx: Double; public var dy: Double
    public init(tabId: String, x: Double, y: Double, dx: Double, dy: Double) { self.tabId = tabId; self.x = x; self.y = y; self.dx = dx; self.dy = dy }
}

public enum KeyEventType: String, Codable, Sendable { case down, up }

public struct BrowserKeyParams: Codable, Sendable, Hashable {
    public var tabId: String; public var type: KeyEventType; public var key: String; public var code: String
    public var text: String?
    /// CDP modifier bits: Alt=1, Ctrl=2, Meta=4, Shift=8.
    public var modifiers: Int
    public init(tabId: String, type: KeyEventType, key: String, code: String, text: String? = nil, modifiers: Int = 0) {
        self.tabId = tabId; self.type = type; self.key = key; self.code = code; self.text = text; self.modifiers = modifiers
    }
}

public struct BrowserTextParams: Codable, Sendable, Hashable {
    public var tabId: String; public var text: String
    public init(tabId: String, text: String) { self.tabId = tabId; self.text = text }
}

public struct BrowserScreenshot: Codable, Sendable, Hashable {
    public var dataBase64: String
    public init(dataBase64: String) { self.dataBase64 = dataBase64 }
    public var data: Data? { Data(base64Encoded: dataBase64) }
}

/// Why the host ended a browser stream on its own.
public enum BrowserDetachReason: String, OpenStringEnum {
    /// Another phone attached to the same tab and took over its screencast.
    case displaced
    case unknown
    public static var unknownFallback: Self { .unknown }
}

/// `browser.detached` event: the host stopped `streamId` without a
/// `browser.detach` from this phone.
public struct BrowserDetachedEvent: Codable, Sendable, Hashable {
    public var streamId: UInt32
    public var tabId: String
    public var reason: BrowserDetachReason
    public init(streamId: UInt32, tabId: String, reason: BrowserDetachReason) {
        self.streamId = streamId; self.tabId = tabId; self.reason = reason
    }
}

/// `browser.focus` event: focus in the streamed page moved onto or off an
/// editable element (sent only to the stream's owner, also after every tap).
public struct BrowserFocusEvent: Codable, Sendable, Hashable {
    public var tabId: String
    public var streamId: UInt32
    public var editable: Bool
    /// False only for a single-line `<input>`.
    public var multiline: Bool?
    /// The `<input>`'s `type` (text, search, url, email, ...).
    public var inputType: String?
    public var inputMode: String?
    public var enterKeyHint: String?
    /// Touch, pointer or key input reached the page within the last second.
    public var userInitiated: Bool?
    public init(tabId: String, streamId: UInt32, editable: Bool, multiline: Bool? = nil, inputType: String? = nil,
                inputMode: String? = nil, enterKeyHint: String? = nil, userInitiated: Bool? = nil) {
        self.tabId = tabId; self.streamId = streamId; self.editable = editable; self.multiline = multiline
        self.inputType = inputType; self.inputMode = inputMode; self.enterKeyHint = enterKeyHint; self.userInitiated = userInitiated
    }
}

/// `browser.closed` event.
public struct BrowserClosedEvent: Codable, Sendable, Hashable { public var tabId: String; public init(tabId: String) { self.tabId = tabId } }

/// `browser.macStatus` state: whether browser.* serves the Mac's own tabs.
public enum BrowserMacState: String, OpenStringEnum {
    /// browser.* serves the Mac's browser tabs.
    case on
    /// The Mac's "Allow cmux on iPhone to view browser tabs" setting is off.
    case off
    /// The Mac's cmux build has no such setting.
    case unsupported
    /// On, but the Mac's endpoint failed validation (`reason`).
    case unavailable
    public static var unknownFallback: Self { .unavailable }
}

/// `browser.macStatus {}` result and event (`browser.mac.v1`).
public struct BrowserMacStatus: Codable, Sendable, Hashable {
    public var state: BrowserMacState
    public var reason: String?
    public var restartRequired: Bool?
    public var hostName: String?
    public init(state: BrowserMacState, reason: String? = nil, restartRequired: Bool? = nil, hostName: String? = nil) {
        self.state = state; self.reason = reason; self.restartRequired = restartRequired; self.hostName = hostName
    }
}

/// One entry of a tab's session history (`browser.history`).
public struct BrowserHistoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var url: String
    /// May be empty (Safari then shows the address).
    public var title: String
    public init(id: Int, url: String, title: String) { self.id = id; self.url = url; self.title = title }
}

/// `browser.history {tabId}` result: oldest first, `entries[currentIndex]` is shown.
public struct BrowserHistoryList: Codable, Sendable, Hashable {
    public var currentIndex: Int
    public var entries: [BrowserHistoryEntry]
    public init(currentIndex: Int, entries: [BrowserHistoryEntry]) { self.currentIndex = currentIndex; self.entries = entries }

    /// The back menu: the previous page first, going back.
    public var backEntries: [BrowserHistoryEntry] {
        guard currentIndex > 0, currentIndex <= entries.count else { return [] }
        return entries[..<currentIndex].reversed()
    }

    /// The forward menu: the next page first.
    public var forwardEntries: [BrowserHistoryEntry] {
        guard currentIndex >= 0, currentIndex + 1 < entries.count else { return [] }
        return Array(entries[(currentIndex + 1)...])
    }
}

/// `browser.goToHistory {tabId, entryId}`.
public struct BrowserGoToHistoryParams: Codable, Sendable, Hashable {
    public var tabId: String
    public var entryId: Int
    public init(tabId: String, entryId: Int) { self.tabId = tabId; self.entryId = entryId }
}
