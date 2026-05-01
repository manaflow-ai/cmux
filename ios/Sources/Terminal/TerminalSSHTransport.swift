import Foundation
import OSLog
@preconcurrency import NIOCore
@preconcurrency import NIOSSH
@preconcurrency import NIOTransportServices

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "terminal.ssh-factory")

struct TerminalGridSize: Equatable, Sendable {
    var columns: Int
    var rows: Int
    var pixelWidth: Int
    var pixelHeight: Int
}

enum TerminalTransportEvent: Sendable {
    case connected
    case output(Data)
    case disconnected(String?)
    case notice(String)
    case trustedHostKey(String)
    case remotePlatform(RemotePlatform)
    /// Daemon-authoritative rendering grid. Emitted by the remote-daemon
    /// transport when the daemon broadcasts `session.view_size` or
    /// returns an updated effective size inline in an RPC response.
    /// Client applies directly; surface letterboxes if container larger.
    case viewSize(cols: Int, rows: Int)
}

protocol TerminalTransport: AnyObject {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)? { get set }
    func connect(initialSize: TerminalGridSize) async throws
    func send(_ data: Data) async throws
    func resize(_ size: TerminalGridSize) async
    func disconnect() async
}

protocol TerminalSessionParking: AnyObject {
    func suspendPreservingSession() async
}

protocol TerminalTransportFactory {
    func makeTransport(
        host: TerminalHost,
        credentials: TerminalSSHCredentials,
        sessionName: String,
        resumeState: TerminalRemoteDaemonResumeState?
    ) -> TerminalTransport
}

struct TerminalSSHConnectionComponents {
    let rootChannel: Channel
    let serverDelegate: TerminalSSHServerAuthenticationDelegate
}

private struct TerminalSSHClientConfigurationBox: @unchecked Sendable {
    let value: SSHClientConfiguration
}

private struct TerminalChannelHandlerContextBox: @unchecked Sendable {
    let value: ChannelHandlerContext
}

func terminalOpenSSHConnection(
    host: TerminalHost,
    credentials: TerminalSSHCredentials
) async throws -> TerminalSSHConnectionComponents {
    let serverDelegate = TerminalSSHServerAuthenticationDelegate(trustedHostKey: host.trustedHostKey)
    let authDelegate = TerminalSSHAuthenticationDelegate(
        username: host.username,
        authenticationMethod: host.sshAuthenticationMethod,
        credentials: credentials
    )
    let config = TerminalSSHClientConfigurationBox(value: SSHClientConfiguration(
        userAuthDelegate: authDelegate,
        serverAuthDelegate: serverDelegate
    ))

    let bootstrap = NIOTSConnectionBootstrap(group: TerminalSSHTransportProtection.eventLoopGroup)
        .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
        .channelInitializer { channel in
            do {
                try channel.pipeline.syncOperations.addHandlers([
                    NIOSSHHandler(
                        role: .client(config.value),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    ),
                    TerminalSSHAuthenticationHandler(eventLoop: channel.eventLoop, timeout: .seconds(15)),
                    NIOCloseOnErrorHandler(),
                ])
                return channel.eventLoop.makeSucceededFuture(())
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }

    let rootChannel = try await bootstrap.connect(host: host.hostname, port: host.port).get()
    let authHandler = try await rootChannel.pipeline.handler(type: TerminalSSHAuthenticationHandler.self).get()
    try await authHandler.authenticated.get()

    return TerminalSSHConnectionComponents(rootChannel: rootChannel, serverDelegate: serverDelegate)
}

func terminalOpenSSHSessionChannel(
    rootChannel: Channel,
    initializer: ((Channel) -> EventLoopFuture<Void>)? = nil
) async throws -> Channel {
    let childPromise = rootChannel.eventLoop.makePromise(of: Channel.self)
    rootChannel.eventLoop.execute {
        do {
            let sshHandler = try rootChannel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
            sshHandler.createChannel(childPromise, channelType: .session) { channel, _ in
                initializer?(channel) ?? channel.eventLoop.makeSucceededFuture(())
            }
        } catch {
            childPromise.fail(error)
        }
    }
    return try await childPromise.futureResult.get()
}

struct DefaultTerminalTransportFactory: TerminalTransportFactory {
    let remoteDaemonBuilder: ((TerminalHost, TerminalSSHCredentials, String, TerminalRemoteDaemonResumeState?) -> TerminalTransport)?
    let daemonTicketService: any TerminalDaemonTicketProviding

    init(
        remoteDaemonBuilder: ((TerminalHost, TerminalSSHCredentials, String, TerminalRemoteDaemonResumeState?) -> TerminalTransport)? = nil,
        daemonTicketService: any TerminalDaemonTicketProviding = TerminalDaemonTicketService()
    ) {
        self.remoteDaemonBuilder = remoteDaemonBuilder
        self.daemonTicketService = daemonTicketService
    }

    func makeTransport(
        host: TerminalHost,
        credentials: TerminalSSHCredentials,
        sessionName: String,
        resumeState: TerminalRemoteDaemonResumeState?
    ) -> TerminalTransport {
        log.debug("TransportFactory: hostname=\(host.hostname, privacy: .public) wsPort=\(host.wsPort.map(String.init) ?? "nil", privacy: .public) wsSecret=\(host.wsSecret != nil ? "set" : "nil", privacy: .public) transportPref=\(String(describing: host.transportPreference), privacy: .public) teamID=\(host.teamID ?? "nil", privacy: .public) hasWebSocket=\(host.hasWebSocketEndpoint, privacy: .public)")
        if host.hasWebSocketEndpoint {
            log.debug("TransportFactory: → WebSocket transport")
            return TerminalWebSocketTransport(
                host: host,
                sessionName: sessionName,
                resumeState: resumeState
            )
        }
        if host.transportPreference == .remoteDaemon {
            if let remoteDaemonBuilder {
                log.debug("TransportFactory: → custom remoteDaemon builder")
                return remoteDaemonBuilder(host, credentials, sessionName, resumeState)
            }
            log.debug("TransportFactory: → TerminalDirectDaemonTransport")
            return TerminalDirectDaemonTransport(
                host: host,
                credentials: credentials,
                sessionName: sessionName,
                resumeState: resumeState,
                ticketService: daemonTicketService
            )
        }
        log.debug("TransportFactory: → raw SSH transport")
        return TerminalSSHTransport(host: host, credentials: credentials, sessionName: sessionName)
    }
}

final class TerminalSSHTransport: @unchecked Sendable, TerminalTransport {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    private let host: TerminalHost
    private let credentials: TerminalSSHCredentials
    private let sessionName: String

    /// Protects `rootChannel`, `shellChannel`, and `closed` from concurrent access.
    /// These fields are mutated from the caller's async context and read/written from
    /// NIO event loop callbacks (`closeFuture.whenComplete`, shell handler `onClose`).
    private let lock = NSLock()
    private var rootChannel: Channel?
    private var shellChannel: Channel?
    private var closed = false

    init(host: TerminalHost, credentials: TerminalSSHCredentials, sessionName: String) {
        self.host = host
        self.credentials = credentials
        self.sessionName = sessionName
    }

    func connect(initialSize: TerminalGridSize) async throws {
        let connection = try await terminalOpenSSHConnection(host: host, credentials: credentials)
        let rootChannel = connection.rootChannel
        lock.withLock { self.rootChannel = rootChannel }

        rootChannel.closeFuture.whenComplete { [weak self] result in
            self?.finishDisconnect(error: result.failureReason?.localizedDescription)
        }

        let shellChannel = try await terminalOpenSSHSessionChannel(rootChannel: rootChannel)
        lock.withLock { self.shellChannel = shellChannel }

        let shellHandler = TerminalSSHShellHandler(
            eventLoop: shellChannel.eventLoop,
            initialSize: initialSize,
            onData: { [weak self] data in
                self?.eventHandler?(.output(data))
            },
            onClose: { [weak self] message in
                self?.finishDisconnect(error: message)
            }
        )
        try await shellChannel.pipeline.addHandlers([shellHandler, NIOCloseOnErrorHandler()]).get()
        try await shellHandler.started.get()

        eventHandler?(.connected)
        try await send(Data("export COLORTERM=truecolor; tmux setenv -g COLORTERM truecolor 2>/dev/null\n".utf8))
        let bootstrapCommand = host.bootstrapCommand.replacingOccurrences(of: "{{session}}", with: sessionName)
        try await send(Data((bootstrapCommand + "\n").utf8))
    }

    func send(_ data: Data) async throws {
        let channel = lock.withLock { shellChannel }
        guard let channel else { return }
        try await channel.eventLoop.submit {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            return channel.writeAndFlush(
                SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            )
        }
        .flatMap { $0 }
        .get()
    }

    func resize(_ size: TerminalGridSize) async {
        let channel = lock.withLock { shellChannel }
        guard let channel else { return }
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: max(1, size.columns),
            terminalRowHeight: max(1, size.rows),
            terminalPixelWidth: max(1, size.pixelWidth),
            terminalPixelHeight: max(1, size.pixelHeight)
        )
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.eventLoop.execute {
            channel.triggerUserOutboundEvent(request, promise: promise)
        }
        _ = try? await promise.futureResult.get()
    }

    func disconnect() async {
        let channel = lock.withLock { rootChannel }
        guard let channel else { return }
        try? await channel.close().get()
        finishDisconnect(error: nil)
    }

    private func finishDisconnect(error: String?) {
        let shouldEmit = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldEmit else { return }
        eventHandler?(.disconnected(error))
    }
}

enum TerminalSSHTransportProtection {
    static let eventLoopGroup = NIOTSEventLoopGroup()
}

final class TerminalSSHAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let authenticationMethod: TerminalSSHAuthenticationMethod
    private let credentials: TerminalSSHCredentials
    private var hasOfferedAuthentication = false

    init(
        username: String,
        authenticationMethod: TerminalSSHAuthenticationMethod,
        credentials: TerminalSSHCredentials
    ) {
        self.username = username
        self.authenticationMethod = authenticationMethod
        self.credentials = credentials
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !hasOfferedAuthentication else {
            nextChallengePromise.succeed(nil)
            return
        }
        hasOfferedAuthentication = true

        do {
            nextChallengePromise.succeed(
                try NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: offer(for: availableMethods)
                )
            )
        } catch {
            nextChallengePromise.fail(error)
        }
    }

    private func offer(
        for availableMethods: NIOSSHAvailableUserAuthenticationMethods
    ) throws -> NIOSSHUserAuthenticationOffer.Offer {
        switch authenticationMethod {
        case .password:
            guard availableMethods.contains(.password) else {
                throw TerminalSSHError.passwordAuthenticationUnavailable
            }
            guard let password = credentials.password, !password.isEmpty else {
                throw TerminalSSHError.missingPassword
            }
            return .password(.init(password: password))
        case .privateKey:
            guard availableMethods.contains(.publicKey) else {
                throw TerminalSSHError.publicKeyAuthenticationUnavailable
            }
            guard let privateKeyText = credentials.privateKey, !privateKeyText.isEmpty else {
                throw TerminalSSHError.missingPrivateKey
            }
            let parsedKey = try TerminalSSHPrivateKeyParser.parse(privateKeyText)
            return .privateKey(.init(privateKey: parsedKey.privateKey))
        }
    }
}

final class TerminalSSHServerAuthenticationDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let trustedHostKey: String?
    private(set) var capturedHostKey: String?

    init(trustedHostKey: String?) {
        self.trustedHostKey = trustedHostKey
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let openSSHPublicKey = String(openSSHPublicKey: hostKey)
        capturedHostKey = openSSHPublicKey

        if let trustedHostKey, trustedHostKey != openSSHPublicKey {
            validationCompletePromise.fail(TerminalSSHError.hostKeyChanged(openSSHPublicKey))
            return
        }

        if trustedHostKey == nil {
            validationCompletePromise.fail(TerminalSSHError.untrustedHostKey(openSSHPublicKey))
            return
        }

        validationCompletePromise.succeed(())
    }
}

final class TerminalSSHAuthenticationHandler: @unchecked Sendable, ChannelInboundHandler {
    typealias InboundIn = Any

    let authenticated: EventLoopFuture<Void>

    private let promise: EventLoopPromise<Void>
    private let timeoutTask: Scheduled<Void>

    init(eventLoop: EventLoop, timeout: TimeAmount) {
        let promise = eventLoop.makePromise(of: Void.self)
        self.promise = promise
        self.authenticated = promise.futureResult
        self.timeoutTask = eventLoop.scheduleTask(in: timeout) {
            promise.fail(TerminalSSHError.authenticationTimedOut)
        }
    }

    deinit {
        timeoutTask.cancel()
        promise.fail(TerminalSSHError.channelClosedBeforeAuthentication)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            promise.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }
}

private final class TerminalSSHShellHandler: @unchecked Sendable, ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    let started: EventLoopFuture<Void>

    private let startPromise: EventLoopPromise<Void>
    private let initialSize: TerminalGridSize
    private let onData: (Data) -> Void
    private let onClose: (String?) -> Void
    private var hasClosed = false

    init(
        eventLoop: EventLoop,
        initialSize: TerminalGridSize,
        onData: @escaping (Data) -> Void,
        onClose: @escaping (String?) -> Void
    ) {
        self.startPromise = eventLoop.makePromise(of: Void.self)
        self.started = startPromise.futureResult
        self.initialSize = initialSize
        self.onData = onData
        self.onClose = onClose
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let contextBox = TerminalChannelHandlerContextBox(value: context)
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .flatMap {
                let context = contextBox.value
                let ptyPromise = context.eventLoop.makePromise(of: Void.self)
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: max(1, self.initialSize.columns),
                    terminalRowHeight: max(1, self.initialSize.rows),
                    terminalPixelWidth: max(1, self.initialSize.pixelWidth),
                    terminalPixelHeight: max(1, self.initialSize.pixelHeight),
                    terminalModes: SSHTerminalModes([:])
                )
                context.triggerUserOutboundEvent(request, promise: ptyPromise)
                return ptyPromise.futureResult
            }
            .flatMap {
                let context = contextBox.value
                let shellPromise = context.eventLoop.makePromise(of: Void.self)
                context.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.ShellRequest(wantReply: true),
                    promise: shellPromise
                )
                return shellPromise.futureResult
            }
            .whenComplete { result in
                self.startPromise.completeWith(result)
            }

        context.channel.closeFuture.whenComplete { _ in
            self.finishClose(message: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data,
              let data = buffer.readData(length: buffer.readableBytes) else {
            return
        }

        switch channelData.type {
        case .channel, .stdErr:
            onData(data)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finishClose(message: error.localizedDescription)
        context.close(promise: nil)
    }

    private func finishClose(message: String?) {
        guard !hasClosed else { return }
        hasClosed = true
        onClose(message)
    }
}

enum TerminalSSHError: LocalizedError {
    case passwordAuthenticationUnavailable
    case publicKeyAuthenticationUnavailable
    case missingPassword
    case missingPrivateKey
    case authenticationTimedOut
    case channelClosedBeforeAuthentication
    case untrustedHostKey(String)
    case hostKeyChanged(String)

    var errorDescription: String? {
        switch self {
        case .passwordAuthenticationUnavailable:
            return String(
                localized: "terminal.ssh.password_unavailable",
                defaultValue: "Password authentication is unavailable on this server."
            )
        case .publicKeyAuthenticationUnavailable:
            return String(
                localized: "terminal.ssh.public_key_unavailable",
                defaultValue: "Public key authentication is unavailable on this server."
            )
        case .missingPassword:
            return String(
                localized: "terminal.ssh.password_missing",
                defaultValue: "Add a password for this server."
            )
        case .missingPrivateKey:
            return String(
                localized: "terminal.ssh.private_key_missing",
                defaultValue: "Add a private key for this server."
            )
        case .authenticationTimedOut:
            return String(
                localized: "terminal.ssh.authentication_timed_out",
                defaultValue: "SSH authentication timed out."
            )
        case .channelClosedBeforeAuthentication:
            return String(
                localized: "terminal.ssh.channel_closed_before_auth",
                defaultValue: "The SSH channel closed before authentication completed."
            )
        case .untrustedHostKey:
            return String(
                localized: "terminal.ssh.untrusted_host_key",
                defaultValue: "Review and trust this server host key before connecting."
            )
        case .hostKeyChanged:
            return String(
                localized: "terminal.ssh.host_key_changed",
                defaultValue: "The server host key changed. Review and trust the new key before connecting."
            )
        }
    }
}

extension Result where Failure == Error {
    var failureReason: Failure? {
        switch self {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
    }
}
