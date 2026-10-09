/// Where a viewer screen's read stands.
public enum ViewerPhase: Hashable, Sendable {
    case idle
    case loading
    case loaded
    case failed(ViewerSourceError)
}
