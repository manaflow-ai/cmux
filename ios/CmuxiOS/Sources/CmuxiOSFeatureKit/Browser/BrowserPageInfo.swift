/// The page as the Mac reports it.
public struct BrowserPageInfo: Hashable, Sendable {
    public var url: String
    public var title: String
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool

    public init(url: String, title: String, isLoading: Bool = false, canGoBack: Bool = false, canGoForward: Bool = false) {
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }
}
