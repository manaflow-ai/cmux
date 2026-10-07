/// Why a viewer read failed, in terms the UI explains.
public enum ViewerSourceError: Error, Hashable, Sendable {
    /// No carrier reaches this Mac yet.
    case noConnection
    /// The workspace has no folder the Mac shares (C4 roots are keyed by workspace id).
    case noWorkspaceFolder
    case notARepository
    case forbidden
    case notFound
    case tooLarge
    /// The path needs a direct or peer connection (relay paths carry control frames only).
    case needsDirectConnection
    case failed(String)

    /// Maps a `cmux.mobile/1` error code.
    public init(code: String, message: String) {
        switch code {
        case "git.not_a_repo": self = .notARepository
        case "git.forbidden", "files.forbidden": self = .forbidden
        case "files.not_found": self = .notFound
        case "files.too_large": self = .tooLarge
        case "link.unsupported_on_path": self = .needsDirectConnection
        default: self = .failed(message.isEmpty ? code : message)
        }
    }
}
