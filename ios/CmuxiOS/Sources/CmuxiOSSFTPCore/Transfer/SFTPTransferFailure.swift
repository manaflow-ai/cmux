import CmuxMobileSSH

/// The `files.*` reason codes C4's transfer list localizes, for SFTP errors.
/// Nil means the transfer can resume (the session dropped).
struct SFTPTransferFailure {
    static func reason(for error: any Error) -> String? {
        switch error {
        case SFTPError.connectionLost: nil
        case SFTPError.noSuchFile: "files.not_found"
        case SFTPError.permissionDenied: "files.forbidden"
        case SFTPHostDirectory.Failure.noSession: "files.unavailable"
        default: "files.unavailable"
        }
    }
}
