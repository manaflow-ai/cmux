import CmuxiOSRemoteDesktopCore

extension RemoteDesktopFailure {
    /// What the screen says, in the user's language.
    var message: String {
        switch self {
        case .unreachable: RemoteDesktopText.failureUnreachable
        case .screenRecordingOff: RemoteDesktopText.failureScreenRecording
        case .consentDenied: RemoteDesktopText.failureConsentDenied
        case .stoppedOnMac: RemoteDesktopText.failureStopped
        case .displayNotFound: RemoteDesktopText.failureDisplay
        case .windowNotFound: RemoteDesktopText.failureWindow
        case .vncNotAllowed: RemoteDesktopText.failureVncNotAllowed
        case .vncUnreachable: RemoteDesktopText.failureVncUnreachable
        case .vncAuthUnsupported: RemoteDesktopText.failureVncAuthUnsupported
        case .vncAuthFailed: RemoteDesktopText.failureVncAuthFailed
        case .permissionRevoked: RemoteDesktopText.failurePermissionRevoked
        case .ended: RemoteDesktopText.failureEnded
        case .revoked: RemoteDesktopText.failureRevoked
        case .other(let code): RemoteDesktopText.format(RemoteDesktopText.failureOther, code)
        }
    }
}
