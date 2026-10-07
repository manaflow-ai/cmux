/// A pointer event (touch, pointer or pen).
public struct BrowserPointerEvent: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case move, down, up
    }

    public var kind: Kind
    public var x: Double
    public var y: Double
    /// 0 primary, 2 secondary (context menu).
    public var button: Int
    /// Mac click count for this press (2 = double click).
    public var clickCount: Int
    public var modifiers: BrowserModifiers
    /// `touch`, `mouse` or `pen`.
    public var pointerType: String

    public init(kind: Kind, x: Double, y: Double, button: Int = 0, clickCount: Int = 1, modifiers: BrowserModifiers = [],
                pointerType: String = "touch") {
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.clickCount = clickCount
        self.modifiers = modifiers
        self.pointerType = pointerType
    }
}
