import Foundation
import OSLog

private let cmxIrohRelayModeDefault: UInt32 = 0

#if DEBUG
nonisolated private let cmxIrohSessionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "terminal-session"
)

nonisolated private func cmuxIrohSessionDebugLog(_ message: String) {
    cmxIrohSessionLogger.debug("\(message, privacy: .public)")
}
#endif

@MainActor
final class CmxIrohTerminalSession: CmxTerminalSession {
    private static let heartbeatInterval: TimeInterval = 5
    private static let maximumMainActorBatchMessages = 256
    private static let maximumMainActorBatchBytes = 256 * 1024

    weak var delegate: CmxTerminalSessionDelegate?

    private let ticket: String
    private let pairingSecret: String?
    nonisolated private let incomingMessageBuffer = CmxIrohIncomingMessageBuffer()
    private var handle: OpaquePointer?
    private var retainedSelf: UnsafeMutableRawPointer?
    private var heartbeatTimer: Timer?
    private var closedByClient = false
    private var didNotifyEnd = false
    private var nextCommandID: UInt32 = 1
    private var heartbeat = CmxHeartbeatState()

    init(ticket: String, pairingSecret: String?) {
        self.ticket = ticket.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pairingSecret = pairingSecret
    }

    isolated deinit {
        stopHeartbeat()
        if let handle {
            cmux_iroh_client_disconnect(handle)
        }
        if let retainedSelf {
            Unmanaged<CmxIrohTerminalSession>.fromOpaque(retainedSelf).release()
        }
    }

    func start(viewport: CmxWireViewport) {
        closedByClient = false
        didNotifyEnd = false
        stopHeartbeat()
        heartbeat.reset()
        retainCallbackContextIfNeeded()
        let context = retainedSelf
        let startedHandle: OpaquePointer? = ticket.withCString { ticketPointer in
            if let pairingSecret {
                return pairingSecret.withCString { secretPointer in
                    cmux_iroh_client_connect(
                        ticketPointer,
                        secretPointer,
                        cmxIrohRelayModeDefault,
                        cmxIrohClientCallback,
                        context
                    )
                }
            }
            return cmux_iroh_client_connect(
                ticketPointer,
                nil,
                cmxIrohRelayModeDefault,
                cmxIrohClientCallback,
                context
            )
        }

        guard let startedHandle else {
            releaseCallbackContextIfNeeded()
            delegate?.terminalSession(self, didFail: CmxIrohTerminalSessionError.failedToStart)
            return
        }

        handle = startedHandle
        send(.helloNative(viewport: viewport, token: nil))
    }

    func sendInput(_ data: Data, terminalID: UInt64) {
        send(.nativeInput(tabID: terminalID, data: data))
    }

    func sendResize(_ viewport: CmxWireViewport, terminalID: UInt64) {
        send(.nativeLayout([
            CmxWireTerminalViewport(tabID: terminalID, cols: viewport.cols, rows: viewport.rows),
        ]))
    }

    func sendNativeLayout(_ terminals: [CmxWireTerminalViewport]) {
        send(.nativeLayout(terminals))
    }

    func requestPtyReplay(terminalID: UInt64) {
        send(.requestPtyReplay(tabID: terminalID))
    }

    func sendCommand(_ command: CmxClientCommand) {
        let id = nextCommandID
        nextCommandID = nextCommandID == UInt32.max ? 1 : nextCommandID + 1
        send(.command(id: id, command))
    }

    func disconnect() {
        closedByClient = true
        stopHeartbeat()
        send(.detach)
        disconnectTransport()
    }

    private func send(_ message: CmxClientMessage) {
        guard let handle else { return }
        do {
            let payload = try CmxWireCodec.encode(message)
            let sent = payload.withUnsafeBytes { bytes in
                cmux_iroh_client_send(
                    handle,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    payload.count
                )
            }
            if !sent {
                failTransport(CmxIrohTerminalSessionError.sendFailed)
            }
        } catch {
            failTransport(error)
        }
    }

    nonisolated fileprivate func enqueueMessageEvent(_ data: Data) {
        guard incomingMessageBuffer.enqueue(data) else { return }
        Task { @MainActor [weak self] in
            self?.drainMessageEvents()
        }
    }

    fileprivate func handleEvent(kind: CmxIrohClientEventKind, data: Data) {
        drainMessageEvents()
        switch kind.rawValue {
        case CmxIrohClientEventKindConnected.rawValue:
            #if DEBUG
            cmuxIrohSessionDebugLog("transport.connected")
            #endif
            startHeartbeat()
        case CmxIrohClientEventKindMessage.rawValue:
            do {
                let message = try CmxWireCodec.decodeServerMessage(data)
                if case .pong = message {
                    recordPong()
                }
                delegate?.terminalSession(self, didReceive: message)
            } catch {
                failTransport(error)
            }
        case CmxIrohClientEventKindClosed.rawValue:
            closeTransport()
        case CmxIrohClientEventKindError.rawValue:
            let message = String(data: data, encoding: .utf8) ?? ""
            failTransport(CmxIrohTerminalSessionError.remoteError(message))
        default:
            failTransport(CmxIrohTerminalSessionError.unknownEvent)
        }
    }

    private func drainMessageEvents() {
        let batch = incomingMessageBuffer.dequeueBatch(
            maxMessages: Self.maximumMainActorBatchMessages,
            maxBytes: Self.maximumMainActorBatchBytes
        )
        guard !batch.messages.isEmpty else { return }

        var decodedMessages: [CmxServerMessage] = []
        decodedMessages.reserveCapacity(batch.messages.count)
        do {
            for data in batch.messages {
                let message = try CmxWireCodec.decodeServerMessage(data)
                if case .pong = message {
                    recordPong()
                }
                decodedMessages.append(message)
            }
        } catch {
            incomingMessageBuffer.cancelScheduledDrain()
            failTransport(error)
            return
        }

        delegate?.terminalSession(self, didReceive: decodedMessages)
        if batch.hasMore {
            Task { @MainActor [weak self] in
                self?.drainMessageEvents()
            }
        }
    }

    private func closeTransport() {
        guard !didNotifyEnd else { return }
        didNotifyEnd = true
        stopHeartbeat()
        disconnectTransport()
        if !closedByClient {
            delegate?.terminalSessionDidClose(self)
        }
    }

    private func failTransport(_ error: Error) {
        guard !didNotifyEnd else { return }
        didNotifyEnd = true
        stopHeartbeat()
        disconnectTransport()
        if !closedByClient {
            delegate?.terminalSession(self, didFail: error)
        }
    }

    private func disconnectTransport() {
        guard let handle else {
            releaseCallbackContextIfNeeded()
            return
        }
        self.handle = nil
        cmux_iroh_client_disconnect(handle)
        releaseCallbackContextIfNeeded()
    }

    private func retainCallbackContextIfNeeded() {
        guard retainedSelf == nil else { return }
        retainedSelf = Unmanaged.passRetained(self).toOpaque()
    }

    private func releaseCallbackContextIfNeeded() {
        guard let retainedSelf else { return }
        Unmanaged<CmxIrohTerminalSession>.fromOpaque(retainedSelf).release()
        self.retainedSelf = nil
    }

    private func startHeartbeat() {
        stopHeartbeat()
        sendPing()
        let timer = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.handle != nil, !self.closedByClient else { return }
                self.sendPing()
            }
        }
        heartbeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        heartbeat.reset()
    }

    private func recordPong() {
        guard let latencyMilliseconds = heartbeat.recordPong() else { return }
        delegate?.terminalSession(self, didUpdateLatencyMilliseconds: latencyMilliseconds)
        send(.clientLatency(milliseconds: latencyMilliseconds))
    }

    private func sendPing() {
        switch heartbeat.tick() {
        case .sendPing:
            send(.ping)
        case .waitForPong:
            break
        case .timedOut:
            failTransport(CmxIrohTerminalSessionError.heartbeatTimedOut)
        }
    }
}

private let cmxIrohClientCallback: CmxIrohClientCallback = { userData, kind, data, len in
    guard let userData else { return }
    let session = Unmanaged<CmxIrohTerminalSession>.fromOpaque(userData).takeUnretainedValue()
    let payload: Data
    if let data, len > 0 {
        payload = Data(bytes: data, count: len)
    } else {
        payload = Data()
    }
    if kind.rawValue == CmxIrohClientEventKindMessage.rawValue {
        session.enqueueMessageEvent(payload)
        return
    }
    Task { @MainActor in
        session.handleEvent(kind: kind, data: payload)
    }
}

private final class CmxIrohIncomingMessageBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [Data] = []
    private var drainScheduled = false

    func enqueue(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        messages.append(data)
        guard !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    func dequeueBatch(maxMessages: Int, maxBytes: Int) -> (messages: [Data], hasMore: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !messages.isEmpty else {
            drainScheduled = false
            return ([], false)
        }

        var batchCount = 0
        var batchBytes = 0
        while batchCount < messages.count, batchCount < maxMessages {
            let nextBytes = messages[batchCount].count
            if batchCount > 0, batchBytes + nextBytes > maxBytes {
                break
            }
            batchBytes += nextBytes
            batchCount += 1
        }

        let batch = Array(messages.prefix(batchCount))
        messages.removeFirst(batchCount)
        drainScheduled = !messages.isEmpty
        return (batch, !messages.isEmpty)
    }

    func cancelScheduledDrain() {
        lock.lock()
        messages.removeAll(keepingCapacity: false)
        drainScheduled = false
        lock.unlock()
    }
}

enum CmxIrohTerminalSessionError: LocalizedError, Equatable {
    case failedToStart
    case sendFailed
    case remoteError(String)
    case unknownEvent
    case heartbeatTimedOut

    var errorDescription: String? {
        switch self {
        case .failedToStart:
            String(localized: "iroh.error.start", defaultValue: "Could not start the terminal connection.")
        case .sendFailed:
            String(localized: "iroh.error.send", defaultValue: "Could not send data to the terminal connection.")
        case .remoteError(let message):
            String(
                format: String(localized: "iroh.error.remote", defaultValue: "Connection failed: %@"),
                message.isEmpty ? String(localized: "iroh.error.remote_unknown", defaultValue: "unknown error") : message
            )
        case .unknownEvent:
            String(localized: "iroh.error.unknown_event", defaultValue: "The terminal connection sent an unknown event.")
        case .heartbeatTimedOut:
            String(localized: "iroh.error.heartbeat_timeout", defaultValue: "The terminal connection stopped responding.")
        }
    }
}
