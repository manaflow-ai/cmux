import Foundation
import OSLog

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "terminal.websocket")

enum TerminalWebSocketTransportError: LocalizedError {
    case invalidURL
    case handshakeRejected(String)
    case unexpectedMessageType
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(
                localized: "terminal.websocket.invalid_url",
                defaultValue: "Invalid WebSocket server URL."
            )
        case .handshakeRejected(let message):
            return message
        case .unexpectedMessageType:
            return String(
                localized: "terminal.websocket.unexpected_message",
                defaultValue: "Received unexpected message from server."
            )
        case .connectionClosed:
            return String(
                localized: "terminal.websocket.connection_closed",
                defaultValue: "WebSocket connection closed."
            )
        }
    }
}

final class TerminalWebSocketDaemonClient: Sendable {

    func connect(
        host: String,
        port: Int,
        secret: String,
        timeoutSeconds: TimeInterval = 8
    ) async throws -> any TerminalRemoteDaemonTransport {
        guard let url = URL(string: "ws://\(host):\(port)") else {
            throw TerminalWebSocketTransportError.invalidURL
        }

        log.debug("Connecting to \(host, privacy: .public):\(port, privacy: .public)")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: url)
        task.resume()

        let handshakePayload: [String: Any] = ["secret": secret]
        let handshakeData = try JSONSerialization.data(withJSONObject: handshakePayload)
        let handshakeString = String(data: handshakeData, encoding: .utf8) ?? "{}"
        try await task.send(.string(handshakeString))

        let response = try await task.receive()
        let responseString: String
        switch response {
        case .string(let text):
            responseString = text
        case .data(let data):
            responseString = String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            session.invalidateAndCancel()
            throw TerminalWebSocketTransportError.unexpectedMessageType
        }

        guard let responseData = responseString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              json["ok"] as? Bool == true else {
            let errorMessage = parseErrorMessage(from: responseString)
            session.invalidateAndCancel()
            throw TerminalWebSocketTransportError.handshakeRejected(
                errorMessage ?? String(
                    localized: "terminal.websocket.auth_failed",
                    defaultValue: "WebSocket authentication failed."
                )
            )
        }

        log.debug("Connection established to \(host, privacy: .public):\(port, privacy: .public)")

        return TerminalWebSocketLineTransport(session: session, webSocket: task)
    }

    private func parseErrorMessage(from response: String) -> String? {
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String,
              !message.isEmpty else {
            return nil
        }
        return message
    }
}

actor TerminalWebSocketLineTransport: TerminalRemoteDaemonTransport {
    private let session: URLSession
    private let webSocket: URLSessionWebSocketTask

    init(session: URLSession, webSocket: URLSessionWebSocketTask) {
        self.session = session
        self.webSocket = webSocket
    }

    func writeLine(_ line: String) async throws {
        guard webSocket.state == .running else {
            throw TerminalWebSocketTransportError.connectionClosed
        }
        try await webSocket.send(.string(line))
    }

    func readLine() async throws -> String {
        let message = try await webSocket.receive()
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            throw TerminalWebSocketTransportError.unexpectedMessageType
        }
    }

    func cancel() {
        log.debug("Disconnecting, invalidating session")
        webSocket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

final class TerminalWebSocketTransport: @unchecked Sendable, TerminalTransport {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    private let host: TerminalHost
    private let sessionName: String
    private let pool: TerminalDaemonConnectionPool
    private let sessionTransportFactory: @Sendable (
        TerminalRemoteDaemonClient,
        String,
        String,
        TerminalRemoteDaemonResumeState?
    ) -> TerminalTransport
    private let resumeState: TerminalRemoteDaemonResumeState?
    private let stateQueue = DispatchQueue(label: "TerminalWebSocketTransport.state")

    private var activeTransport: TerminalTransport?
    private var lastKnownResumeState: TerminalRemoteDaemonResumeState?

    init(
        host: TerminalHost,
        sessionName: String,
        resumeState: TerminalRemoteDaemonResumeState? = nil,
        pool: TerminalDaemonConnectionPool = .shared,
        sessionTransportFactory: @escaping @Sendable (
            TerminalRemoteDaemonClient,
            String,
            String,
            TerminalRemoteDaemonResumeState?
        ) -> TerminalTransport = { client, command, sessionName, resumeState in
            TerminalRemoteDaemonSessionTransport(
                client: client,
                command: command,
                sharedSessionID: sessionName,
                resumeState: resumeState
            )
        }
    ) {
        self.host = host
        self.sessionName = sessionName
        self.resumeState = resumeState
        self.pool = pool
        self.sessionTransportFactory = sessionTransportFactory
        self.lastKnownResumeState = resumeState
    }

    func connect(initialSize: TerminalGridSize) async throws {
        guard let wsPort = host.wsPort,
              let wsSecret = host.wsSecret,
              !wsSecret.isEmpty else {
            throw TerminalWebSocketTransportError.invalidURL
        }

        log.debug("Transport connecting to \(self.host.hostname, privacy: .public):\(wsPort, privacy: .public) session=\(self.sessionName, privacy: .public) (pooled)")

        // Reuse the pooled ws + RPC client for this daemon. The connection
        // owns the URLSessionWebSocketTask; on transport failure it will be
        // re-established on next acquireClient() call.
        let connection = pool.connection(
            stableID: host.stableID,
            hostname: host.hostname,
            port: wsPort,
            secret: wsSecret
        )
        let (client, _) = try await connection.acquireClient()

        let effectiveSessionName = sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "cmux-\(UUID().uuidString.prefix(8).lowercased())"
            : sessionName
        // WebSocket connects to the daemon which manages its own PTY sessions.
        // Request a login shell. The daemon runs on the Mac, so /bin/zsh -l
        // gives the user their normal shell environment.
        let command = "TERM=xterm-256color COLORTERM=truecolor /bin/zsh -l"
        // WebSocket always connects to the local Mac daemon, so we know the platform.
        eventHandler?(.remotePlatform(RemotePlatform(goOS: "darwin", goArch: "arm64")))

        let transport = sessionTransportFactory(client, command, effectiveSessionName, resumeState)
        transport.eventHandler = { [weak self, weak transport] event in
            self?.handle(event: event, activeTransport: transport)
        }
        stateQueue.sync { self.activeTransport = transport }

        do {
            try await transport.connect(initialSize: initialSize)
        } catch {
            stateQueue.sync { self.activeTransport = nil }
            throw error
        }
    }

    func send(_ data: Data) async throws {
        guard let transport = stateQueue.sync(execute: { activeTransport }) else { return }
        try await transport.send(data)
    }

    func resize(_ size: TerminalGridSize) async {
        guard let transport = stateQueue.sync(execute: { activeTransport }) else { return }
        await transport.resize(size)
    }

    func disconnect() async {
        log.debug("Transport disconnecting session=\(self.sessionName, privacy: .public)")
        let transport = stateQueue.sync { () -> TerminalTransport? in
            let t = activeTransport
            activeTransport = nil
            lastKnownResumeState = nil
            return t
        }
        await transport?.disconnect()
        // Pool-owned ws stays open for other sessions/workspace subscription.
    }

    private func handle(event: TerminalTransportEvent, activeTransport: TerminalTransport?) {
        if let snapshotting = activeTransport as? TerminalRemoteDaemonResumeStateSnapshotting {
            stateQueue.sync {
                lastKnownResumeState = snapshotting.remoteDaemonResumeStateSnapshot()
            }
        }
        if case .disconnected = event {
            stateQueue.sync { self.activeTransport = nil }
        }
        eventHandler?(event)
    }
}

extension TerminalWebSocketTransport: TerminalRemoteDaemonResumeStateSnapshotting {
    func remoteDaemonResumeStateSnapshot() -> TerminalRemoteDaemonResumeState? {
        stateQueue.sync { lastKnownResumeState }
    }
}

extension TerminalWebSocketTransport: TerminalSessionParking {
    func suspendPreservingSession() async {
        let transport = stateQueue.sync { () -> TerminalTransport? in
            let t = activeTransport
            activeTransport = nil
            return t
        }
        if let parking = transport as? TerminalSessionParking {
            await parking.suspendPreservingSession()
        } else {
            await transport?.disconnect()
            stateQueue.sync { lastKnownResumeState = nil }
        }
        // Pool-owned ws stays open.
    }
}
