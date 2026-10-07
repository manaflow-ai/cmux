/// Low-rate page events of a stream.
public enum BrowserPageUpdate: Hashable, Sendable {
    case page(BrowserPageInfo)
    /// The page viewport in CSS pixels (input coordinates are in this space).
    case pageSize(width: Double, height: Double)
    /// CSS cursor name under the pointer (`text`, `pointer`, `default`, ...).
    case cursor(String)
    /// A text field gained (true) or lost (false) focus.
    case textFocus(Bool)
    /// The page copied text: put it on the pasteboard.
    case clipboard(String)
}
