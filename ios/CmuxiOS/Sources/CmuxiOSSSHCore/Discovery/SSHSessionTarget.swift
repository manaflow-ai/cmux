import CmuxMobileSSH
import Foundation

/// A discovered session an SSH workspace can attach to. Built only from a
/// discovery listing (`SSHSessionDiscovery`), so every id in it passed
/// `SSHSessionName` and every path `SSHRemoteBinary`.
public enum SSHSessionTarget: Hashable, Sendable {
    /// A tmux session, or one window of it.
    case tmux(binary: SSHRemoteBinary, session: SSHSessionName, window: Int?)
    /// A window addressed by host-issued ids, through tmux control mode.
    case tmuxControl(binary: SSHRemoteBinary, window: SSHTmuxWindow)
    /// A GNU screen session (`<pid>.<name>`).
    case screen(binary: SSHRemoteBinary, session: SSHSessionName)
    /// An existing cmux-tui owner at the exact socket discovery found.
    case cmuxTUI(binary: SSHRemoteBinary, socket: SSHCmuxTUISocket)

    /// The command the PTY runs (`exec`, so the session ends with the
    /// client). Every argument is quoted; no part comes from free text.
    public var attachCommand: String {
        switch self {
        case .tmux(let binary, let session, let window):
            // `=` makes tmux match the session name exactly, never a prefix.
            let target = "=" + session.rawValue + (window.map { ":\($0)" } ?? "")
            return "exec \(binary.quoted) attach-session -t \(target.posixShellSingleQuoted)"
        case .tmuxControl(let binary, let window):
            // -N refuses to start a new server; -E preserves the host's environment.
            // A session id never changes its active window as name:index attach does.
            return "exec \(binary.quoted) -C -N attach-session -E -f ignore-size,no-output -t \(window.sessionID.posixShellSingleQuoted)"
        case .screen(let binary, let session):
            // `-x` joins without detaching other clients.
            return "exec \(binary.quoted) -x \(session.rawValue.posixShellSingleQuoted)"
        case .cmuxTUI(let binary, let socket):
            // `attach` fails if the owner exited. Plain `--session` may
            // create a replacement owner and derives its socket again.
            return "exec \(binary.quoted) attach --socket \(socket.path.posixShellSingleQuoted)"
        }
    }

    /// A stable id for the terminal surface (`ssh:<kind>:<session>[:<window>]`).
    public var surfaceID: String {
        switch self {
        case .tmux(_, let session, let window): "ssh:tmux:" + session.rawValue + (window.map { ":\($0)" } ?? "")
        case .tmuxControl(_, let window): "ssh:tmux:\(window.serverPID)-\(window.serverStart):" + window.sessionID + ":" + window.windowID
        case .screen(_, let session): "ssh:screen:" + session.rawValue
        case .cmuxTUI(_, let socket): "ssh:cmux-tui:" + socket.session.rawValue
        }
    }
}
