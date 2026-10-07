/// Settings pages another screen can open directly (search, links).
public enum ShellSettingsPage: String, Hashable, Sendable, Identifiable {
    case terminal
    case notifications
    case privacy

    public var id: String { rawValue }
}
