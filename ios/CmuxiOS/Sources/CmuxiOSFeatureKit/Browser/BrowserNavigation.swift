public import Foundation

/// Navigation ops on the tab record (owned by the workspace store).
public enum BrowserNavigation: Hashable, Sendable {
    case load(URL)
    case back
    case forward
    case reload
}
