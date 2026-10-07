public import CmuxiOSFeatureKit

extension FeedIntent {
    /// The op params the feed owner takes for this intent (feed.md section 6),
    /// as Foundation JSON. The same encoding the WebSocket source sends, for
    /// one-shot senders such as banner actions (c7-notify.md section 2).
    public func wireParams(device: String?) -> [String: Any] {
        FeedWireEncode.params(self, device: device)
    }
}
