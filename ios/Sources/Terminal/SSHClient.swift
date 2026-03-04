import Foundation

// MARK: - Connection State

/// SSH connection lifecycle states.
enum SSHConnectionState: Equatable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case failed(SSHError)
}

// MARK: - Errors

enum SSHError: Error, Equatable, LocalizedError {
    case notConnected
    case authenticationFailed(String)
    case connectionFailed(String)
    case channelError(String)
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to SSH server"
        case .authenticationFailed(let msg): return "Authentication failed: \(msg)"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .channelError(let msg): return "Channel error: \(msg)"
        case .notImplemented: return "Not implemented"
        }
    }
}

// MARK: - Protocols

/// Protocol for SSH client implementations (libssh2, NIO-SSH, etc.)
protocol SSHClientProtocol: AnyObject {
    var state: SSHConnectionState { get }
    var onStateChange: ((SSHConnectionState) -> Void)? { get set }

    func connect(host: String, port: Int) async throws
    func authenticate(username: String, privateKey: Data) async throws
    func execute(command: String) async throws -> CommandResult
    func startShell(cols: UInt16, rows: UInt16) async throws -> SSHChannel
    func disconnect()
}

/// Result of executing a remote command.
struct CommandResult {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

/// SSH channel for interactive shell sessions.
protocol SSHChannel: AnyObject {
    func write(_ data: Data) async throws
    func read() async throws -> Data
    func resize(cols: UInt16, rows: UInt16) async throws
    func close() async throws
}

// MARK: - libssh2 Implementation (Stub)

/// Concrete SSH client backed by libssh2.
/// Placeholder: methods throw `.notImplemented` until the libssh2 xcframework is integrated.
final class LibSSH2Client: SSHClientProtocol {
    private(set) var state: SSHConnectionState = .disconnected {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((SSHConnectionState) -> Void)?

    private var host: String?
    private var port: Int?

    func connect(host: String, port: Int) async throws {
        state = .connecting
        self.host = host
        self.port = port
        // TODO: libssh2_session_init, libssh2_session_handshake
        throw SSHError.notImplemented
    }

    func authenticate(username: String, privateKey: Data) async throws {
        guard case .connecting = state else { throw SSHError.notConnected }
        state = .authenticating
        // TODO: libssh2_userauth_publickey_frommemory
        throw SSHError.notImplemented
    }

    func execute(command: String) async throws -> CommandResult {
        guard case .connected = state else { throw SSHError.notConnected }
        // TODO: libssh2_channel_exec
        throw SSHError.notImplemented
    }

    func startShell(cols: UInt16, rows: UInt16) async throws -> SSHChannel {
        guard case .connected = state else { throw SSHError.notConnected }
        // TODO: libssh2_channel_open_session + request_pty + shell
        throw SSHError.notImplemented
    }

    func disconnect() {
        // TODO: libssh2_session_disconnect, libssh2_session_free
        host = nil
        port = nil
        state = .disconnected
    }
}

// MARK: - libssh2 Channel (Stub)

/// Interactive shell channel backed by libssh2.
final class LibSSH2Channel: SSHChannel {
    func write(_ data: Data) async throws {
        throw SSHError.notImplemented
    }

    func read() async throws -> Data {
        throw SSHError.notImplemented
    }

    func resize(cols: UInt16, rows: UInt16) async throws {
        throw SSHError.notImplemented
    }

    func close() async throws {
        throw SSHError.notImplemented
    }
}
