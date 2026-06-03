import Foundation
import CryptoKit
import Network
import Security

protocol TerminalDirectDaemonConnection: Sendable {
    func start() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func cancel() async
}

protocol TerminalDirectDaemonConnecting: Sendable {
    func connect(url: URL, ticket: String, certificatePins: [String]) async throws -> any TerminalRemoteDaemonTransport
}

enum TerminalDirectDaemonClientError: LocalizedError, Equatable {
    case invalidURL(String)
    case connectionFailed(String)
    case tlsRejected(String)
    case invalidHandshake(String)
    case handshakeRejected(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            let prefix = String(
                localized: "terminal.workspace.error.direct_invalid_url",
                defaultValue: "Invalid direct daemon URL"
            )
            return "\(prefix): \(url)"
        case .connectionFailed(let message):
            let prefix = String(
                localized: "terminal.workspace.error.direct_connection_failed",
                defaultValue: "Direct daemon connection failed"
            )
            return "\(prefix): \(message)"
        case .tlsRejected(let message):
            let prefix = String(
                localized: "terminal.workspace.error.direct_tls_rejected",
                defaultValue: "Direct daemon TLS verification failed"
            )
            return "\(prefix): \(message)"
        case .invalidHandshake(let line):
            let prefix = String(
                localized: "terminal.workspace.error.direct_invalid_handshake",
                defaultValue: "Invalid direct daemon handshake"
            )
            return "\(prefix): \(line)"
        case .handshakeRejected(let code, let message):
            if code == "unauthorized" || code == "forbidden" {
                return String(
                    localized: "terminal.workspace.error.direct_auth_rejected",
                    defaultValue: "Direct daemon rejected this session."
                )
            }
            return message
        }
    }
}

actor TerminalDirectDaemonClient: TerminalDirectDaemonConnecting {
    private let connectionFactory: @Sendable (String, UInt16, [String]) -> any TerminalDirectDaemonConnection
    private let connectionStartTimeout: TimeInterval
    private let handshakeTimeout: TimeInterval

    init(
        connectionFactory: @escaping @Sendable (String, UInt16, [String]) -> any TerminalDirectDaemonConnection = { host, port, certificatePins in
            TerminalNetworkDirectDaemonConnection(host: host, port: port, certificatePins: certificatePins)
        },
        connectionStartTimeout: TimeInterval = 8,
        handshakeTimeout: TimeInterval = 5
    ) {
        self.connectionFactory = connectionFactory
        self.connectionStartTimeout = connectionStartTimeout
        self.handshakeTimeout = handshakeTimeout
    }

    func connect(url: URL, ticket: String, certificatePins: [String] = []) async throws -> any TerminalRemoteDaemonTransport {
        guard url.scheme?.lowercased() == "tls",
              let host = url.host else {
            throw TerminalDirectDaemonClientError.invalidURL(url.absoluteString)
        }
        let port = UInt16(url.port ?? 9443)
        let connection = connectionFactory(host, port, certificatePins)

        do {
            try await withTimeout(
                seconds: connectionStartTimeout,
                timeoutError: .connectionFailed(Self.connectionTimedOutDetail()),
                onTimeout: { await connection.cancel() }
            ) {
                try await connection.start()
            }
        } catch let error as TerminalDirectDaemonClientError {
            throw error
        } catch {
            throw TerminalDirectDaemonClientError.connectionFailed(error.localizedDescription)
        }

        let transport = TerminalDirectDaemonLineTransport(connection: connection)
        do {
            return try await withTimeout(
                seconds: handshakeTimeout,
                timeoutError: .connectionFailed(Self.handshakeTimedOutDetail()),
                onTimeout: { await connection.cancel() }
            ) {
                try await transport.writeLine(Self.handshakeLine(ticket: ticket))
                let responseLine = try await transport.readLine()
                let response = try Self.decodeHandshake(from: responseLine)
                guard response.ok else {
                    let error = response.error ?? DirectDaemonHandshakeError(
                        code: "unauthorized",
                        message: "ticket rejected"
                    )
                    throw TerminalDirectDaemonClientError.handshakeRejected(
                        code: error.code,
                        message: error.message
                    )
                }
                return transport
            }
        } catch let error as TerminalDirectDaemonClientError {
            if !Self.isTimeoutError(error) {
                await connection.cancel()
            }
            throw error
        } catch {
            await connection.cancel()
            throw TerminalDirectDaemonClientError.connectionFailed(error.localizedDescription)
        }
    }

    private static func connectionTimedOutDetail() -> String {
        String(
            localized: "terminal.workspace.error.direct_connection_timeout_detail",
            defaultValue: "connection timed out"
        )
    }

    private static func handshakeTimedOutDetail() -> String {
        String(
            localized: "terminal.workspace.error.direct_handshake_timeout_detail",
            defaultValue: "handshake timed out"
        )
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        timeoutError: TerminalDirectDaemonClientError,
        onTimeout: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await TerminalAsyncTimeout.run(
            seconds: seconds,
            timeoutError: { timeoutError },
            onTimeout: onTimeout,
            operation: operation
        )
    }

    private static func isTimeoutError(_ error: TerminalDirectDaemonClientError) -> Bool {
        error == .connectionFailed(connectionTimedOutDetail()) ||
            error == .connectionFailed(handshakeTimedOutDetail())
    }

    private static func handshakeLine(ticket: String) throws -> String {
        let payload = ["ticket": ticket]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeHandshake(from line: String) throws -> DirectDaemonHandshakeResponse {
        guard let data = line.data(using: .utf8) else {
            throw TerminalDirectDaemonClientError.invalidHandshake(line)
        }
        do {
            return try JSONDecoder().decode(DirectDaemonHandshakeResponse.self, from: data)
        } catch {
            throw TerminalDirectDaemonClientError.invalidHandshake(line)
        }
    }
}

private struct DirectDaemonHandshakeResponse: Decodable {
    let ok: Bool
    let error: DirectDaemonHandshakeError?
}

private struct DirectDaemonHandshakeError: Decodable {
    let code: String
    let message: String
}

private actor TerminalDirectDaemonLineTransport: TerminalRemoteDaemonTransport {
    private let connection: any TerminalDirectDaemonConnection
    private var buffer = Data()

    init(connection: any TerminalDirectDaemonConnection) {
        self.connection = connection
    }

    func writeLine(_ line: String) async throws {
        var data = Data(line.utf8)
        if data.last != 0x0A {
            data.append(0x0A)
        }
        try await connection.send(data)
    }

    func readLine() async throws -> String {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                var line = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                if line.last == 0x0D {
                    line.removeLast()
                }
                return String(decoding: line, as: UTF8.self)
            }

            let chunk = try await connection.receive()
            if chunk.isEmpty {
                throw TerminalDirectDaemonClientError.connectionFailed("connection closed")
            }
            buffer.append(chunk)
        }
    }
}

private actor TerminalNetworkDirectDaemonConnection: TerminalDirectDaemonConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "TerminalNetworkDirectDaemonConnection.queue")
    private let tlsValidationState: TLSValidationState
    private var started = false

    init(host: String, port: UInt16, certificatePins: [String] = []) {
        let tlsValidationState = TLSValidationState()
        self.tlsValidationState = tlsValidationState
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv13
        )
        if !certificatePins.isEmpty {
            let expectedPins = Set(certificatePins.map(Self.normalizeCertificatePin(_:)))
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, trust, completion in
                    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                    let leafCertificatePin = Self.leafCertificatePin(for: secTrust)
                    guard let leafCertificatePin else {
                        tlsValidationState.set(
                            .tlsRejected("missing leaf certificate")
                        )
                        completion(false)
                        return
                    }
                    guard expectedPins.contains(leafCertificatePin) else {
                        tlsValidationState.set(
                            .tlsRejected("certificate pin mismatch")
                        )
                        completion(false)
                        return
                    }
                    completion(true)
                },
                queue
            )
        }
        let tcpOptions = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: 9443)!
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: parameters
        )
    }

    private static func leafCertificatePin(for trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else { return nil }
        let data = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizeCertificatePin(_ pin: String) -> String {
        let trimmed = pin
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if trimmed.hasPrefix("sha256:") {
            return trimmed
        }
        return "sha256:" + trimmed
    }

    func start() async throws {
        guard !started else { return }
        started = true

        let startState = StartResolutionState()
        let tlsValidationState = self.tlsValidationState
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard startState.beginResolution() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard startState.beginResolution() else { return }
                    continuation.resume(throwing: Self.classify(error, tlsValidationState: tlsValidationState))
                case .waiting(let error):
                    guard startState.beginResolution() else { return }
                    continuation.resume(throwing: Self.classify(error, tlsValidationState: tlsValidationState))
                case .cancelled:
                    guard startState.beginResolution() else { return }
                    continuation.resume(throwing: TerminalDirectDaemonClientError.connectionFailed("connection cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        let tlsValidationState = self.tlsValidationState
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: Self.classify(error, tlsValidationState: tlsValidationState))
                    return
                }
                continuation.resume()
            })
        }
    }

    func receive() async throws -> Data {
        let tlsValidationState = self.tlsValidationState
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: Self.classify(error, tlsValidationState: tlsValidationState))
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(throwing: TerminalDirectDaemonClientError.connectionFailed("connection closed"))
                    return
                }
                continuation.resume(throwing: TerminalDirectDaemonClientError.connectionFailed("no data received"))
            }
        }
    }

    func cancel() async {
        connection.cancel()
    }

    private static func classify(
        _ error: Error,
        tlsValidationState: TLSValidationState
    ) -> TerminalDirectDaemonClientError {
        if let recorded = tlsValidationState.value() {
            return recorded
        }

        if let error = error as? TerminalDirectDaemonClientError {
            return error
        }

        if let nwError = error as? NWError {
            switch nwError {
            case .tls(let status):
                let message = (SecCopyErrorMessageString(status, nil) as String?) ?? nwError.localizedDescription
                return .tlsRejected(message)
            case .dns, .posix, .wifiAware:
                return .connectionFailed(nwError.localizedDescription)
            @unknown default:
                return .connectionFailed(nwError.localizedDescription)
            }
        }

        return .connectionFailed(error.localizedDescription)
    }
}

private final class StartResolutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func beginResolution() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !resolved else { return false }
        resolved = true
        return true
    }
}

private final class TLSValidationState: @unchecked Sendable {
    private let lock = NSLock()
    private var error: TerminalDirectDaemonClientError?

    func set(_ error: TerminalDirectDaemonClientError) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func value() -> TerminalDirectDaemonClientError? {
        lock.lock()
        let snapshot = error
        lock.unlock()
        return snapshot
    }
}
