public import Foundation
@preconcurrency import Citadel
@preconcurrency import NIO
@preconcurrency import NIOSSH
import Crypto
public import Logging

/// `CmuxSSHTransport` implementation backed by Citadel (pure-Swift SwiftNIO SSH).
///
/// One instance owns one `SSHClient` and serializes connection lifecycle via
/// an actor. Each exec call opens a fresh SSH channel — Citadel multiplexes
/// channels over the underlying TCP connection.
///
/// Verified against Citadel 0.12.1 API surface (see `docs/architecture.md`
/// for the exact symbols this depends on; if Citadel's surface shifts in a
/// minor release, the breakage is localized to this file).
public actor CitadelSSHTransport: CmuxSSHTransport {

    public enum HostKeyPolicy: Sendable {
        /// Pin to a previously-observed OpenSSH SHA256 host-key fingerprint.
        /// The transport refuses to connect to anything else.
        case pinFingerprintSHA256(String)
        /// Trust-on-first-use. The caller must explicitly accept and persist
        /// the fingerprint before returning true. Returning false fails the
        /// SSH handshake before credentials are sent.
        case trustOnFirstUse(onTOFU: @Sendable (String) async -> Bool)
        /// Accept any host key (only for development; flagged in the UI).
        case acceptAny
    }

    private let log: Logger
    private let host: String
    private let port: Int
    private let username: String
    private let authFactory: @Sendable () throws -> SSHAuthenticationMethod
    private let hostKeyPolicy: HostKeyPolicy
    private let connectTimeout: TimeAmount
    private var client: SSHClient?
    private static let streamingStderrTailLimit = 64 * 1024

    public init(
        host: String,
        port: Int,
        username: String,
        credential: CmuxResolvedCredential,
        hostKeyPolicy: HostKeyPolicy,
        connectTimeoutSeconds: Int = 15,
        logger: Logger = CmuxLog.make("ssh.citadel")
    ) throws {
        self.log = logger
        self.host = host
        self.port = port
        self.username = username
        self.hostKeyPolicy = hostKeyPolicy
        self.connectTimeout = .seconds(Int64(connectTimeoutSeconds))
        self.authFactory = { try Self.makeAuthMethod(username: username, credential: credential) }
    }

    /// Host-key-only probe for TOFU. This deliberately sends SSH "none" auth
    /// after host-key validation instead of a bogus password, so accepting a
    /// new host key never creates a real credential attempt.
    public init(
        host: String,
        port: Int,
        username: String,
        hostKeyPolicy: HostKeyPolicy,
        connectTimeoutSeconds: Int = 15,
        logger: Logger = CmuxLog.make("ssh.citadel")
    ) throws {
        self.log = logger
        self.host = host
        self.port = port
        self.username = username
        self.hostKeyPolicy = hostKeyPolicy
        self.connectTimeout = .seconds(Int64(connectTimeoutSeconds))
        self.authFactory = { SSHAuthenticationMethod.custom(HostKeyProbeAuthentication(username: username)) }
    }

    private static func makeAuthMethod(
        username: String,
        credential: CmuxResolvedCredential
    ) throws -> SSHAuthenticationMethod {
        switch credential.material {
        case .password(let pw):
            return .passwordBased(username: username, password: pw)
        case .ed25519PrivateKey(let raw):
            do {
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
                return .ed25519(username: username, privateKey: key)
            } catch {
                throw CmuxError.transport("invalid ed25519 private key bytes", underlying: error)
            }
        case .ecdsaP256PrivateKey(let raw):
            do {
                let key = try P256.Signing.PrivateKey(rawRepresentation: raw)
                return .p256(username: username, privateKey: key)
            } catch {
                throw CmuxError.transport("invalid P-256 private key bytes", underlying: error)
            }
        case .rsaPrivateKey:
            throw CmuxError.transport(
                "RSA keys are not supported. Use ed25519 or P-256.",
                underlying: nil
            )
        case .secureEnclaveSigner:
            throw CmuxError.transport(
                "Secure-Enclave-signing auth path is staged behind a follow-up implementation",
                underlying: nil
            )
        }
    }

    private func ensureConnected() async throws -> SSHClient {
        if let existing = client, existing.isConnected {
            return existing
        }
        client = nil

        let validator: SSHHostKeyValidator
        switch hostKeyPolicy {
        case .pinFingerprintSHA256(let pin):
            validator = .custom(PinnedFingerprintValidator(expectedFingerprint: pin, log: log))
        case .trustOnFirstUse(let onTOFU):
            validator = .custom(TOFUValidator(onSeen: onTOFU, log: log))
        case .acceptAny:
            validator = .acceptAnything()
        }

        do {
            let client = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: try authFactory(),
                hostKeyValidator: validator,
                reconnect: .never,
                connectTimeout: connectTimeout
            )
            client.onDisconnect { [weak self] in
                Task { [weak self] in await self?.markDisconnected() }
            }
            self.client = client
            log.info("SSH connected", metadata: ["host": "\(host):\(port)", "user": "\(username)"])
            return client
        } catch let error as SSHClientError {
            throw CmuxError.transport("SSH error: \(error)", underlying: error)
        } catch {
            throw CmuxError.transport("Connect failed: \(error)", underlying: error)
        }
    }

    private func markDisconnected() {
        log.info("SSH session disconnected")
        client = nil
    }

    private static func trimStreamingStderrTail(_ buffer: inout Data) {
        let overflow = buffer.count - streamingStderrTailLimit
        if overflow > 0 {
            buffer.removeFirst(overflow)
        }
    }

    public func close() async {
        if let c = client {
            try? await c.close()
        }
        client = nil
    }

    public func ping() async throws -> Duration {
        let start = ContinuousClock.now
        let client = try await ensureConnected()
        // Cheapest liveness probe: run `true` and read EOF. Anything else
        // requires the shell to start, which is too heavy for keepalive.
        _ = try await client.executeCommand("true", maxResponseSize: 4)
        return ContinuousClock.now - start
    }

    // MARK: - One-shot exec

    public func runOneShot(
        command: String,
        stdin: Data?
    ) async throws -> CmuxExecResult {
        let client = try await ensureConnected()

        if let stdin {
            return try await runOneShotWithStdin(client: client, command: command, stdin: stdin)
        }

        var stdoutBuffer = Data()
        var stderrBuffer = Data()
        var exitCode: Int32 = 0
        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                try Task.checkCancellation()
                switch chunk {
                case .stdout(let buf):
                    stdoutBuffer.append(contentsOf: buf.readableBytesView)
                case .stderr(let buf):
                    stderrBuffer.append(contentsOf: buf.readableBytesView)
                }
            }
        } catch let failure as SSHClient.CommandFailed {
            exitCode = Int32(failure.exitCode)
        } catch is CancellationError {
            throw CmuxError.cancelled
        } catch {
            throw CmuxError.transport("exec channel error", underlying: error)
        }

        return CmuxExecResult(
            exitCode: exitCode,
            stdout: stdoutBuffer,
            stderr: stderrBuffer
        )
    }

    private func runOneShotWithStdin(
        client: SSHClient,
        command: String,
        stdin: Data
    ) async throws -> CmuxExecResult {
        // For commands that need stdin (notification feed JSON, claude-hook
        // stdin payloads, etc.) we use `withExec` which gives us a stdin
        // writer.
        let stdoutBox = LockedBox<Data>()
        let stderrBox = LockedBox<Data>()
        let exitBox = LockedBox<Int32>()

        do {
            try await client.withExec(command) { inbound, outbound in
                try await outbound.write(ByteBuffer(bytes: stdin))
                try await outbound.write(ByteBuffer(string: ""))   // EOF signal
                // Note: Citadel doesn't expose explicit EOF on TTYStdinWriter;
                // we close the channel after the closure returns. Most cmux
                // commands that read stdin tolerate the writer being closed
                // by the channel teardown.
                for try await chunk in inbound {
                    switch chunk {
                    case .stdout(let buf):
                        stdoutBox.append(contentsOf: buf.readableBytesView)
                    case .stderr(let buf):
                        stderrBox.append(contentsOf: buf.readableBytesView)
                    }
                }
            }
        } catch let failure as SSHClient.CommandFailed {
            exitBox.set(Int32(failure.exitCode))
        } catch is CancellationError {
            throw CmuxError.cancelled
        } catch {
            throw CmuxError.transport("exec(withExec) channel error", underlying: error)
        }

        return CmuxExecResult(
            exitCode: exitBox.value,
            stdout: stdoutBox.value,
            stderr: stderrBox.value
        )
    }

    // MARK: - Line stream

    public nonisolated func runLineStream(
        command: String,
        onStderrLine: @Sendable @escaping (String) -> Void
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                var stderrBuffer = Data()
                do {
                    let client = try await self.ensureConnected()
                    let stream = try await client.executeCommandStream(command)
                    var stdoutTail = Data()
                    var stderrTail = Data()
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        switch chunk {
                        case .stdout(let buf):
                            stdoutTail.append(contentsOf: buf.readableBytesView)
                            while let nl = stdoutTail.firstIndex(of: 0x0A) {
                                let lineData = stdoutTail.prefix(upTo: nl)
                                stdoutTail.removeSubrange(...nl)
                                if let line = String(data: lineData, encoding: .utf8) {
                                    continuation.yield(line)
                                } else {
                                    continuation.finish(throwing: CmuxError.decoding(
                                        "non-UTF8 line in stdout", underlying: nil))
                                    return
                                }
                            }
                        case .stderr(let buf):
                            stderrTail.append(contentsOf: buf.readableBytesView)
                            stderrBuffer.append(contentsOf: buf.readableBytesView)
                            Self.trimStreamingStderrTail(&stderrBuffer)
                            while let nl = stderrTail.firstIndex(of: 0x0A) {
                                let lineData = stderrTail.prefix(upTo: nl)
                                stderrTail.removeSubrange(...nl)
                                if let line = String(data: lineData, encoding: .utf8) {
                                    onStderrLine(line)
                                }
                            }
                        }
                    }
                    // Flush any unterminated trailing line.
                    if !stdoutTail.isEmpty, let trailing = String(data: stdoutTail, encoding: .utf8) {
                        continuation.yield(trailing)
                    }
                    if !stderrTail.isEmpty, let trailing = String(data: stderrTail, encoding: .utf8) {
                        onStderrLine(trailing)
                    }
                    continuation.finish()
                } catch let failure as SSHClient.CommandFailed {
                    continuation.finish(throwing: CmuxError.command(
                        exitCode: Int32(failure.exitCode),
                        stderr: String(data: stderrBuffer, encoding: .utf8) ?? ""
                    ))
                } catch is CancellationError {
                    continuation.finish(throwing: CmuxError.cancelled)
                } catch {
                    continuation.finish(throwing: CmuxError.transport("line-stream error", underlying: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public nonisolated func runByteStream(
        command: String,
        onStderrLine: @Sendable @escaping (String) -> Void
    ) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                var stderrBuffer = Data()
                do {
                    let client = try await self.ensureConnected()
                    let stream = try await client.executeCommandStream(command)
                    var stderrTail = Data()
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        switch chunk {
                        case .stdout(let buf):
                            continuation.yield(Data(buf.readableBytesView))
                        case .stderr(let buf):
                            stderrTail.append(contentsOf: buf.readableBytesView)
                            stderrBuffer.append(contentsOf: buf.readableBytesView)
                            Self.trimStreamingStderrTail(&stderrBuffer)
                            while let nl = stderrTail.firstIndex(of: 0x0A) {
                                let lineData = stderrTail.prefix(upTo: nl)
                                stderrTail.removeSubrange(...nl)
                                if let line = String(data: lineData, encoding: .utf8) {
                                    onStderrLine(line)
                                }
                            }
                        }
                    }
                    if !stderrTail.isEmpty, let trailing = String(data: stderrTail, encoding: .utf8) {
                        onStderrLine(trailing)
                    }
                    continuation.finish()
                } catch let failure as SSHClient.CommandFailed {
                    continuation.finish(throwing: CmuxError.command(
                        exitCode: Int32(failure.exitCode),
                        stderr: String(data: stderrBuffer, encoding: .utf8) ?? ""
                    ))
                } catch is CancellationError {
                    continuation.finish(throwing: CmuxError.cancelled)
                } catch {
                    continuation.finish(throwing: CmuxError.transport("byte-stream error", underlying: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Host-key validators

private struct PinnedFingerprintValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let expectedFingerprint: String
    let log: Logger

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let actual = Self.fingerprint(for: hostKey)
        if actual == expectedFingerprint {
            validationCompletePromise.succeed(())
        } else {
            log.error("host key fingerprint mismatch", metadata: [
                "expected": "\(expectedFingerprint)",
                "actual": "\(actual)"
            ])
            validationCompletePromise.fail(CmuxError.transport(
                "Host key fingerprint mismatch — refusing to connect.",
                underlying: nil
            ))
        }
    }

    static func fingerprint(for key: NIOSSHPublicKey) -> String {
        // OpenSSH fingerprints hash the decoded public-key blob from the
        // "<algorithm> <base64 key blob>" public-key format, then base64
        // encode the SHA-256 digest without trailing padding.
        let openSSHPublicKey = String(openSSHPublicKey: key)
        let components = openSSHPublicKey.split(
            separator: " ",
            maxSplits: 2,
            omittingEmptySubsequences: true
        )
        guard components.count >= 2,
              let keyBlob = Data(base64Encoded: String(components[1]))
        else {
            let fallbackDigest = SHA256.hash(data: Data(openSSHPublicKey.utf8))
            return "CMUX-SHA256:\(Self.base64NoPadding(fallbackDigest))"
        }
        let digest = SHA256.hash(data: keyBlob)
        return "SHA256:\(Self.base64NoPadding(digest))"
    }

    private static func base64NoPadding(_ digest: SHA256.Digest) -> String {
        Data(digest)
            .base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

private struct TOFUValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let onSeen: @Sendable (String) async -> Bool
    let log: Logger

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let fingerprint = PinnedFingerprintValidator.fingerprint(for: hostKey)
        log.notice("host-key TOFU", metadata: ["fingerprint": "\(fingerprint)"])
        // CRITICAL: persist the fingerprint *before* succeeding the
        // promise. If we succeed first (the previous behaviour),
        // SSH auth proceeds immediately and credentials are sent over
        // a wire whose host key we have not yet recorded — a MITM can
        // present a rogue key, harvest the password / key-signing
        // challenge, then we save THEIR fingerprint after the fact.
        // Awaiting the persist closure here serialises the work onto
        // the NIO event loop's pending-promise window.
        Task.detached {
            if await onSeen(fingerprint) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(CmuxError.transport(
                    "Host key was not trusted.",
                    underlying: nil
                ))
            }
        }
    }
}

private final class HostKeyProbeAuthentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let lock = NSLock()
    private var offeredNone = false

    init(username: String) {
        self.username = username
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock()
        let shouldOfferNone = !offeredNone
        offeredNone = true
        lock.unlock()

        guard shouldOfferNone else {
            nextChallengePromise.fail(CmuxError.transport(
                "Host-key preflight completed before credential authentication.",
                underlying: nil
            ))
            return
        }

        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .none
        ))
    }
}

// MARK: - Tiny locked box

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init() where Value == Data { self._value = Data() }
    init() where Value == Int32 { self._value = 0 }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func set(_ newValue: Value) {
        lock.lock(); defer { lock.unlock() }
        _value = newValue
    }
}

extension LockedBox where Value == Data {
    func append<Bytes: Sequence>(contentsOf bytes: Bytes) where Bytes.Element == UInt8 {
        lock.lock(); defer { lock.unlock() }
        _value.append(contentsOf: bytes)
    }
}
