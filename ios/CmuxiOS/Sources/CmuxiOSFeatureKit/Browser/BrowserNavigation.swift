public import Foundation

/// Navigation ops on the page (owned by the Mac browser host).
public enum BrowserNavigation: Hashable, Sendable {
    case load(URL)
    case back
    case forward
    case reload
    case stop
}
