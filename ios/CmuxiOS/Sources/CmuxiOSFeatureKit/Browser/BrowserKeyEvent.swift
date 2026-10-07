/// A key press as the page sees it: DOM `code` and `key`, typed text.
public struct BrowserKeyEvent: Hashable, Sendable {
    public var down: Bool
    public var code: String
    public var key: String
    public var text: String
    public var modifiers: BrowserModifiers
    public var isRepeat: Bool

    public init(down: Bool, code: String, key: String, text: String = "", modifiers: BrowserModifiers = [], isRepeat: Bool = false) {
        self.down = down
        self.code = code
        self.key = key
        self.text = text
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }
}
