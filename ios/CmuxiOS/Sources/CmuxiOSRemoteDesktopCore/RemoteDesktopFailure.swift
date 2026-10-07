public import CmuxRemoteDesktop

/// What the screen tells the user when a stream cannot open or ends, by the
/// Mac's code (c3-rd.md 2.3, 7, 8). The UI module localizes each case.
public enum RemoteDesktopFailure: Hashable, Sendable {
    case unreachable
    case screenRecordingOff
    case consentDenied
    case stoppedOnMac
    case displayNotFound
    case windowNotFound
    case vncNotAllowed
    case vncUnreachable
    case vncAuthUnsupported
    case vncAuthFailed
    case permissionRevoked
    case ended
    case revoked
    case other(code: String)

    public init(code: String) {
        switch code {
        case "rd.permission_denied": self = .screenRecordingOff
        case "rd.consent_denied", "consent_denied": self = .consentDenied
        case "rd.stopped_by_host", "stopped_by_host": self = .stoppedOnMac
        case "rd.display_not_found": self = .displayNotFound
        case "rd.window_not_found": self = .windowNotFound
        case "rd.vnc_not_allowed": self = .vncNotAllowed
        case "rd.vnc_unreachable", "rd.vnc_closed", "vnc_closed": self = .vncUnreachable
        case "rd.vnc_auth_unsupported": self = .vncAuthUnsupported
        case "rd.vnc_auth_failed", "vnc_auth_failed": self = .vncAuthFailed
        case "rd.permission_revoked", "permission_revoked": self = .permissionRevoked
        case "rd.target_gone", "target_gone", "local", "remote", "closed": self = .ended
        case "auth.revoked", "auth.forbidden", "revoked": self = .revoked
        default: self = .other(code: code)
        }
    }

    public init(_ error: RemoteDesktopClientError) {
        switch error {
        case .refused(let code, _): self.init(code: code)
        case .linkLost, .notOpen: self = .unreachable
        case .protocolViolation: self = .other(code: "protocol")
        }
    }
}
