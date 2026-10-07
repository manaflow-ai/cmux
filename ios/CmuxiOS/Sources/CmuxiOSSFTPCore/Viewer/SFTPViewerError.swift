import CmuxiOSSSHCore
import CmuxiOSViewersCore
import CmuxMobileSSH

/// SFTP and connection errors in the viewers' terms. No server text is
/// shown for connection failures (it can carry host details).
struct SFTPViewerError {
    static func map(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError: error
        case let error as ViewerSourceError: error
        case SFTPError.noSuchFile: ViewerSourceError.notFound
        case SFTPError.permissionDenied: ViewerSourceError.forbidden
        case SFTPError.connectionLost, SFTPHostDirectory.Failure.noSession: ViewerSourceError.noConnection
        case SFTPError.failure(let message): ViewerSourceError.failed(message)
        case let failure as SSHSessionFailure: ViewerSourceError.failed(String(describing: failure))
        default: ViewerSourceError.noConnection
        }
    }
}
