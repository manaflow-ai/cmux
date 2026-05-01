import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

private struct TerminalBootstrapChannelHandlerContextBox: @unchecked Sendable {
    let value: ChannelHandlerContext
}

protocol TerminalRemoteDaemonBootstrapPreparing: Sendable {
    func prepareDaemon() async throws -> TerminalRemoteDaemonLaunchConfig
}

protocol TerminalRemoteDaemonBootstrapSSHSession: AnyObject, TerminalRemoteDaemonCommandRunner, Sendable {
    var capturedHostKey: String? { get }
    func openDaemonTransport(launchCommand: String) async throws -> any TerminalRemoteDaemonTransport
    func disconnect() async
}

extension TerminalRemoteDaemonBootstrapSession: TerminalRemoteDaemonBootstrapPreparing {}

final class TerminalRemoteDaemonBootstrapTransport: @unchecked Sendable, TerminalTransport {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    private let host: TerminalHost
    private let credentials: TerminalSSHCredentials
    private let sessionName: String
    private let resumeState: TerminalRemoteDaemonResumeState?
    private let bootstrapTimeout: TimeInterval
    private let sshSessionFactory: @Sendable (TerminalHost, TerminalSSHCredentials) -> any TerminalRemoteDaemonBootstrapSSHSession
    private let bootstrapSessionFactory: @Sendable (any TerminalRemoteDaemonBootstrapSSHSession) -> any TerminalRemoteDaemonBootstrapPreparing
    private let sessionClientFactory: @Sendable (any TerminalRemoteDaemonTransport) -> any TerminalRemoteDaemonSessionClient
    private let stateQueue = DispatchQueue(label: "TerminalRemoteDaemonBootstrapTransport.state")

    private var sshSession: (any TerminalRemoteDaemonBootstrapSSHSession)?
    private var sessionTransport: TerminalTransport?
    private var lastKnownResumeState: TerminalRemoteDaemonResumeState?

    init(
        host: TerminalHost,
        credentials: TerminalSSHCredentials,
        sessionName: String,
        resumeState: TerminalRemoteDaemonResumeState? = nil,
        bootstrapTimeout: TimeInterval = 12,
        sshSessionFactory: @escaping @Sendable (TerminalHost, TerminalSSHCredentials) -> any TerminalRemoteDaemonBootstrapSSHSession = { host, credentials in
            TerminalLiveRemoteDaemonSSHSession(host: host, credentials: credentials)
        },
        bootstrapSessionFactory: @escaping @Sendable (any TerminalRemoteDaemonBootstrapSSHSession) -> any TerminalRemoteDaemonBootstrapPreparing = { sshSession in
            TerminalRemoteDaemonBootstrapSession(commandRunner: sshSession)
        },
        sessionClientFactory: @escaping @Sendable (any TerminalRemoteDaemonTransport) -> any TerminalRemoteDaemonSessionClient = { transport in
            TerminalRemoteDaemonClient(transport: transport)
        }
    ) {
        self.host = host
        self.credentials = credentials
        self.sessionName = sessionName
        self.resumeState = resumeState
        self.bootstrapTimeout = bootstrapTimeout
        self.sshSessionFactory = sshSessionFactory
        self.bootstrapSessionFactory = bootstrapSessionFactory
        self.sessionClientFactory = sessionClientFactory
        self.lastKnownResumeState = resumeState
    }

    func connect(initialSize: TerminalGridSize) async throws {
        let sshSession = sshSessionFactory(host, credentials)

        do {
            let (daemonTransport, remotePlatform) = try await withTimeout(
                seconds: bootstrapTimeout,
                timeoutError: .bootstrapTimedOut
            ) {
                let bootstrapSession = self.bootstrapSessionFactory(sshSession)
                let launchConfig = try await bootstrapSession.prepareDaemon()
                let transport = try await sshSession.openDaemonTransport(
                    launchCommand: launchConfig.launchCommand
                )
                return (transport, launchConfig.platform)
            }
            eventHandler?(.remotePlatform(remotePlatform))
            let sessionTransport = TerminalRemoteDaemonSessionTransport(
                client: sessionClientFactory(daemonTransport),
                command: host.bootstrapCommand.replacingOccurrences(of: "{{session}}", with: sessionName),
                resumeState: resumeState
            )

            sessionTransport.eventHandler = { [weak self, weak sshSession] event in
                self?.handle(event: event, sshSession: sshSession)
            }

            setState(sshSession: sshSession, sessionTransport: sessionTransport)
            try await sessionTransport.connect(initialSize: initialSize)
        } catch {
            _ = clearState()
            await sshSession.disconnect()
            throw error
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        timeoutError: TerminalRemoteDaemonBootstrapTransportError,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutNanoseconds = Self.timeoutNanoseconds(from: seconds)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                if timeoutNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                }
                throw timeoutError
            }

            defer {
                group.cancelAll()
            }

            guard let result = try await group.next() else {
                throw timeoutError
            }
            return result
        }
    }

    private static func timeoutNanoseconds(from seconds: TimeInterval) -> UInt64 {
        let clampedSeconds = max(seconds, 0)
        let nanoseconds = clampedSeconds * 1_000_000_000
        if nanoseconds >= TimeInterval(UInt64.max) {
            return UInt64.max
        }
        return UInt64(nanoseconds.rounded())
    }

    func send(_ data: Data) async throws {
        guard let sessionTransport = sessionTransportSnapshot() else { return }
        try await sessionTransport.send(data)
    }

    func resize(_ size: TerminalGridSize) async {
        guard let sessionTransport = sessionTransportSnapshot() else { return }
        await sessionTransport.resize(size)
    }

    func disconnect() async {
        let snapshot = clearState()
        await snapshot.sessionTransport?.disconnect()
        await snapshot.sshSession?.disconnect()
        updateLastKnownResumeState(nil)
    }

    func suspendPreservingSession() async {
        let snapshot = clearState()
        if let parkingTransport = snapshot.sessionTransport as? TerminalSessionParking {
            await parkingTransport.suspendPreservingSession()
        } else {
            await snapshot.sessionTransport?.disconnect()
            updateLastKnownResumeState(nil)
        }
        await snapshot.sshSession?.disconnect()
    }

    private func handle(
        event: TerminalTransportEvent,
        sshSession: (any TerminalRemoteDaemonBootstrapSSHSession)?
    ) {
        updateLastKnownResumeState(
            (sessionTransportSnapshot() as? TerminalRemoteDaemonResumeStateSnapshotting)?
                .remoteDaemonResumeStateSnapshot()
        )
        if case .disconnected = event {
            let cleared = clearState(matching: sshSession)
            Task {
                await cleared.sshSession?.disconnect()
            }
        }
        eventHandler?(event)
    }

    private func setState(
        sshSession: any TerminalRemoteDaemonBootstrapSSHSession,
        sessionTransport: TerminalTransport
    ) {
        stateQueue.sync {
            self.sshSession = sshSession
            self.sessionTransport = sessionTransport
        }
    }

    private func sessionTransportSnapshot() -> TerminalTransport? {
        stateQueue.sync { sessionTransport }
    }

    private func updateLastKnownResumeState(_ state: TerminalRemoteDaemonResumeState?) {
        stateQueue.sync {
            lastKnownResumeState = state
        }
    }

    private func clearState(
        matching expectedSSHSession: (any TerminalRemoteDaemonBootstrapSSHSession)? = nil
    ) -> (
        sshSession: (any TerminalRemoteDaemonBootstrapSSHSession)?,
        sessionTransport: TerminalTransport?
    ) {
        stateQueue.sync {
            if let expectedSSHSession,
               let sshSession,
               ObjectIdentifier(sshSession) != ObjectIdentifier(expectedSSHSession) {
                return (nil, nil)
            }

            let snapshot = (sshSession, sessionTransport)
            sshSession = nil
            sessionTransport = nil
            return snapshot
        }
    }
}

extension TerminalRemoteDaemonBootstrapTransport: TerminalRemoteDaemonResumeStateSnapshotting {
    func remoteDaemonResumeStateSnapshot() -> TerminalRemoteDaemonResumeState? {
        stateQueue.sync { lastKnownResumeState }
    }
}

extension TerminalRemoteDaemonBootstrapTransport: TerminalSessionParking {}

final class TerminalLiveRemoteDaemonSSHSession: @unchecked Sendable, TerminalRemoteDaemonBootstrapSSHSession {
    var capturedHostKey: String? {
        stateQueue.sync { capturedHostKeyValue }
    }

    private let host: TerminalHost
    private let credentials: TerminalSSHCredentials
    private let stateQueue = DispatchQueue(label: "TerminalLiveRemoteDaemonSSHSession.state")

    private var connection: TerminalSSHConnectionComponents?
    private var capturedHostKeyValue: String?

    init(host: TerminalHost, credentials: TerminalSSHCredentials) {
        self.host = host
        self.credentials = credentials
    }

    func run(_ command: String) async throws -> String {
        let connection = try await ensureConnection()
        let handler = TerminalSSHExecCommandHandler(
            eventLoop: connection.rootChannel.eventLoop,
            command: command
        )
        _ = try await terminalOpenSSHSessionChannel(rootChannel: connection.rootChannel) { channel in
            channel.pipeline.addHandlers([handler, NIOCloseOnErrorHandler()])
        }
        return try await handler.completed.get()
    }

    func openDaemonTransport(launchCommand: String) async throws -> any TerminalRemoteDaemonTransport {
        let connection = try await ensureConnection()
        let lineReader = TerminalSSHLineReader()
        let handler = TerminalSSHRemoteDaemonLineHandler(
            eventLoop: connection.rootChannel.eventLoop,
            command: launchCommand,
            lineReader: lineReader
        )
        let channel = try await terminalOpenSSHSessionChannel(rootChannel: connection.rootChannel) { channel in
            channel.pipeline.addHandlers([handler, NIOCloseOnErrorHandler()])
        }
        try await handler.started.get()
        return TerminalSSHRemoteDaemonRPCTransport(channel: channel, lineReader: lineReader)
    }

    func disconnect() async {
        let connection = stateQueue.sync { () -> TerminalSSHConnectionComponents? in
            let connection = self.connection
            self.connection = nil
            return connection
        }
        guard let connection else { return }
        try? await connection.rootChannel.close().get()
    }

    private func ensureConnection() async throws -> TerminalSSHConnectionComponents {
        if let existing = stateQueue.sync(execute: { self.connection }), existing.rootChannel.isActive {
            return existing
        }

        let connection = try await terminalOpenSSHConnection(host: host, credentials: credentials)
        connection.rootChannel.closeFuture.whenComplete { [weak self, rootChannel = connection.rootChannel] _ in
            self?.stateQueue.sync {
                guard let self, let current = self.connection, current.rootChannel === rootChannel else { return }
                self.connection = nil
            }
        }

        stateQueue.sync {
            self.connection = connection
            self.capturedHostKeyValue = connection.serverDelegate.capturedHostKey
        }
        return connection
    }
}

private final class TerminalSSHExecCommandHandler: @unchecked Sendable, ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    let completed: EventLoopFuture<String>

    private let completedPromise: EventLoopPromise<String>
    private let command: String
    private var output = Data()
    private var stderr = Data()
    private var exitStatus = 0
    private var finished = false

    init(eventLoop: EventLoop, command: String) {
        self.completedPromise = eventLoop.makePromise(of: String.self)
        self.completed = completedPromise.futureResult
        self.command = command
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let contextBox = TerminalBootstrapChannelHandlerContextBox(value: context)
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .flatMap {
                let context = contextBox.value
                let promise = context.eventLoop.makePromise(of: Void.self)
                context.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.ExecRequest(command: self.command, wantReply: true),
                    promise: promise
                )
                return promise.futureResult
            }
            .whenFailure { [weak self] error in
                self?.finish(with: error)
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data,
              let data = buffer.readData(length: buffer.readableBytes) else {
            return
        }

        switch channelData.type {
        case .channel:
            output.append(data)
        case .stdErr:
            stderr.append(data)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exitStatus = event as? SSHChannelRequestEvent.ExitStatus {
            self.exitStatus = exitStatus.exitStatus
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if exitStatus == 0 {
            finish(with: String(decoding: output + stderr, as: UTF8.self))
        } else {
            let message = String(decoding: stderr + output, as: UTF8.self)
            finish(with: TerminalRemoteDaemonBootstrapTransportError.commandFailed(exitStatus, message))
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(with: error)
        context.close(promise: nil)
    }

    private func finish(with result: String) {
        guard !finished else { return }
        finished = true
        completedPromise.succeed(result)
    }

    private func finish(with error: Error) {
        guard !finished else { return }
        finished = true
        completedPromise.fail(error)
    }
}

private final class TerminalSSHRemoteDaemonLineHandler: @unchecked Sendable, ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    let started: EventLoopFuture<Void>

    private let startedPromise: EventLoopPromise<Void>
    private let command: String
    private let lineReader: TerminalSSHLineReader
    private var finished = false

    init(eventLoop: EventLoop, command: String, lineReader: TerminalSSHLineReader) {
        self.startedPromise = eventLoop.makePromise(of: Void.self)
        self.started = startedPromise.futureResult
        self.command = command
        self.lineReader = lineReader
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let contextBox = TerminalBootstrapChannelHandlerContextBox(value: context)
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .flatMap {
                let context = contextBox.value
                let promise = context.eventLoop.makePromise(of: Void.self)
                context.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.ExecRequest(command: self.command, wantReply: true),
                    promise: promise
                )
                return promise.futureResult
            }
            .whenComplete { [weak self] result in
                self?.startedPromise.completeWith(result)
                if case .failure(let error) = result {
                    self?.finish(error: error)
                }
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data,
              let data = buffer.readData(length: buffer.readableBytes) else {
            return
        }

        if channelData.type == .channel {
            lineReader.yield(data: data)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(error: TerminalRemoteDaemonBootstrapTransportError.channelClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(error: error)
        context.close(promise: nil)
    }

    private func finish(error: Error) {
        guard !finished else { return }
        finished = true
        lineReader.finish(error: error)
    }
}

private final class TerminalSSHRemoteDaemonRPCTransport: @unchecked Sendable, TerminalRemoteDaemonTransport {
    private let channel: Channel
    private let lineReader: TerminalSSHLineReader

    init(channel: Channel, lineReader: TerminalSSHLineReader) {
        self.channel = channel
        self.lineReader = lineReader
    }

    func writeLine(_ line: String) async throws {
        try await channel.eventLoop.submit {
            var buffer = self.channel.allocator.buffer(capacity: line.utf8.count + 1)
            buffer.writeString(line)
            buffer.writeString("\n")
            return self.channel.writeAndFlush(
                SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            )
        }
        .flatMap { $0 }
        .get()
    }

    func readLine() async throws -> String {
        try await lineReader.nextLine()
    }
}

private final class TerminalSSHLineReader: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "TerminalSSHLineReader.state")

    private var bufferedData = Data()
    private var bufferedLines: [String] = []
    private var waitingContinuations: [CheckedContinuation<String, Error>] = []
    private var terminalError: Error?

    func yield(data: Data) {
        stateQueue.sync {
            guard terminalError == nil else { return }
            bufferedData.append(data)

            while let newlineIndex = bufferedData.firstIndex(of: 0x0A) {
                var lineData = bufferedData.prefix(upTo: newlineIndex)
                bufferedData.removeSubrange(...newlineIndex)
                if lineData.last == 0x0D {
                    lineData.removeLast()
                }
                enqueue(line: String(decoding: lineData, as: UTF8.self))
            }
        }
    }

    func finish(error: Error) {
        stateQueue.sync {
            guard terminalError == nil else { return }
            terminalError = error
            let continuations = waitingContinuations
            waitingContinuations.removeAll()
            continuations.forEach { $0.resume(throwing: error) }
        }
    }

    func nextLine() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.sync {
                if !bufferedLines.isEmpty {
                    continuation.resume(returning: bufferedLines.removeFirst())
                    return
                }

                if let terminalError {
                    continuation.resume(throwing: terminalError)
                    return
                }

                waitingContinuations.append(continuation)
            }
        }
    }

    private func enqueue(line: String) {
        if !waitingContinuations.isEmpty {
            let continuation = waitingContinuations.removeFirst()
            continuation.resume(returning: line)
            return
        }

        bufferedLines.append(line)
    }
}

enum TerminalRemoteDaemonBootstrapTransportError: LocalizedError {
    case channelClosed
    case commandFailed(Int, String)
    case bootstrapTimedOut

    var errorDescription: String? {
        switch self {
        case .channelClosed:
            return String(
                localized: "terminal.workspace.error.bootstrap_channel_closed",
                defaultValue: "Remote daemon channel closed."
            )
        case .commandFailed(let exitStatus, let output):
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedOutput.isEmpty {
                let format = String(
                    localized: "terminal.workspace.error.bootstrap_command_failed",
                    defaultValue: "Remote command failed with exit status %lld."
                )
                return String.localizedStringWithFormat(format, Int64(exitStatus))
            }
            let format = String(
                localized: "terminal.workspace.error.bootstrap_command_failed_with_output",
                defaultValue: "Remote command failed with exit status %lld: %@"
            )
            return String.localizedStringWithFormat(format, Int64(exitStatus), trimmedOutput)
        case .bootstrapTimedOut:
            return String(
                localized: "terminal.workspace.error.bootstrap_timeout",
                defaultValue: "Remote daemon bootstrap timed out."
            )
        }
    }
}
