public import CmuxMobileSSH
import Foundation

/// The real connector: the chain through `SSHChainDialer`, then a PTY and a
/// login shell (or, with `command`, that command) on the last hop.
public struct NIOSSHShellConnector: SSHShellConnector {
    private let dialer: SSHChainDialer
    private let term: String
    private let command: String?
    private let tmuxWindow: SSHTmuxWindow?
    private let workspaceChanged: @Sendable () async -> Void

    public init(chain: SSHHostChain, credentials: SSHCredentialResolver, verifier: any SSHHostKeyVerifier,
                keepalive: SSHKeepalive = SSHKeepalive(), term: String = "xterm-256color") {
        dialer = SSHChainDialer(chain: chain, credentials: credentials, verifier: verifier, keepalive: keepalive)
        self.term = term
        command = nil
        tmuxWindow = nil
        workspaceChanged = {}
    }

    /// Attaches to a discovered session instead of starting a login shell.
    public init(dialer: SSHChainDialer, attaching target: SSHSessionTarget, term: String = "xterm-256color",
                workspaceChanged: @escaping @Sendable () async -> Void = {}) {
        self.dialer = dialer
        self.term = term
        command = target.attachCommand
        if case .tmuxControl(_, let window) = target { tmuxWindow = window } else { tmuxWindow = nil }
        self.workspaceChanged = workspaceChanged
    }

    public func openShell(cols: Int, rows: Int) async throws -> any SSHShellChannel {
        let opened = try await dialer.dial()
        do {
            guard let target = opened.last else { throw SSHSessionFailure.invalidChain }
            let start: SSHSessionStart = command.map(SSHSessionStart.exec) ?? .shell
            // Control mode is a byte protocol. A PTY would echo commands and
            // transform newlines, corrupting its response framing.
            let pty = tmuxWindow == nil ? SSHPTYRequest(term: term, columns: cols, rows: rows) : nil
            let session = try await target.openSession(pty: pty, start: start)
            let channel = NIOSSHShellChannel(session: session, connections: opened)
            guard let tmuxWindow else { return channel }
            let control = SSHTmuxControlChannel(base: channel, window: tmuxWindow, cols: cols, rows: rows,
                                               changed: workspaceChanged)
            try await control.start()
            return control
        } catch {
            for connection in opened.reversed() { await connection.close() }
            throw SSHSessionFailure(error)
        }
    }
}
