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
    public init(tabId: String, width: Int, height: Int, scale: Double, mobile: Bool = true) {
        self.tabId = tabId; self.width = width; self.height = height; self.scale = scale; self.mobile = mobile
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

/// `browser.closed` event.
public struct BrowserClosedEvent: Codable, Sendable, Hashable { public var tabId: String; public init(tabId: String) { self.tabId = tabId } }
