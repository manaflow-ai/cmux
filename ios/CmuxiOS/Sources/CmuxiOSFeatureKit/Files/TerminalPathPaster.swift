/// Seam for C1/D1: pastes an uploaded file's Mac path into a terminal as a
/// POSIX single-quoted token plus a space (a `terminal.input` paste record).
public protocol TerminalPathPaster: Sendable {
    func paste(path: String, terminal: String?, host: HostID) async
}
