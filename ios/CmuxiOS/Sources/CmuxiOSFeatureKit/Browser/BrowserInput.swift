import Foundation

/// Input forwarded to the host browser, in page coordinates.
public enum BrowserInput: Hashable, Sendable {
    case tap(x: Double, y: Double)
    case scroll(dx: Double, dy: Double)
    case text(String)
    case key(String)
}
