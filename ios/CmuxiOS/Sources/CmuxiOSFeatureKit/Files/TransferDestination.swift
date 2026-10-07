/// Where an upload lands on the Mac (c4-files.md section 3). `terminal` and
/// `composer` go to the Mac's inbox; `directory` is a writable root path the
/// Mac listed in `files.roots`.
public enum TransferDestination: Hashable, Sendable {
    /// The path is pasted into this terminal afterwards (by `TerminalPathPaster`).
    case terminal(id: String?)
    /// The file is attached to a task (by `FileAttachmentSink`).
    case composer
    case directory(String)
}
