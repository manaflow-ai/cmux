/// Whether the push owner has this device's latest preferences.
public enum NotificationSyncState: Hashable, Sendable {
    /// No sink yet (C7 not landed): the value is kept on this device only.
    case localOnly
    case syncing
    case synced
    /// The owner was unreachable; nothing queued. The next change retries.
    case offline
    case refused(reason: String)
}
