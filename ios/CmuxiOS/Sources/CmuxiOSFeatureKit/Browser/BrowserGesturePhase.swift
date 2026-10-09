/// Scroll gesture phases (the page sees them as wheel phases).
public enum BrowserGesturePhase: String, Hashable, Sendable {
    case none, began, changed, ended, cancelled
}
