/// What the user picked a file for.
public enum FileSendTarget: Hashable, Sendable {
    /// Upload to the inbox, then paste the quoted path into this terminal.
    case terminal(id: String?)
    /// Upload to the inbox, then attach to the task being composed (C8).
    case composer
    /// Save to the Mac's inbox only.
    case inbox
    /// Save into this folder on the host (SSH hosts over SFTP, lane E5).
    case directory(String)
}
