/// What a push is about, as the notification preferences group them. Feed
/// kinds follow `FeedItemKind`; terminal alerts are bells and `cmux.terminal`.
public enum NotificationKind: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case permission
    case question
    case planApproval
    case finished
    case terminalAlert

    public var id: String { rawValue }
}
