import Foundation

private let cmxIrohRelayModeDefault: UInt32 = 0

@MainActor
final class CmxIrohTerminalSession: CmxTerminalSession {
    private static let heartbeatInterval: TimeInterval = 5

    weak var delegate: CmxTerminalSessionDelegate?

    private let ticket: String
    private let pairingSecret: String?
    private var handle: OpaquePointer?
    private var retainedSelf: UnsafeMutableRawPointer?
    private var heartbeatTimer: Timer?
    private var closedByClient = false
    private var nextCommandID: UInt32 = 1

    init(ticket: String, pairingSecret: String?) {
        self.ticket = ticket.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pairingSecret = pairingSecret
    }

    deinit {
        MainActor.assumeIsolated {
            stopHeartbeat()
        }
        if let handle {
            cmux_iroh_client_disconnect(handle)
        }
        if let retainedSelf {
            Unmanaged<CmxIrohTerminalSession>.fromOpaque(retainedSelf).release()
        }
    }

    func start(viewport: CmxWireViewport) {
        closedByClient = false
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
        startHeartbeat()
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

    func sendCommand(_ command: CmxClientCommand) {
        let id = nextCommandID
        nextCommandID = nextCommandID == UInt32.max ? 1 : nextCommandID + 1
        send(.command(id: id, command))
    }

    private func sendPing() {
        send(.ping)
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
                delegate?.terminalSession(self, didFail: CmxIrohTerminalSessionError.sendFailed)
            }
        } catch {
            delegate?.terminalSession(self, didFail: error)
        }
    }

    fileprivate func handleEvent(kind: CmxIrohClientEventKind, data: Data) {
        switch kind.rawValue {
        case CmxIrohClientEventKindConnected.rawValue:
            break
        case CmxIrohClientEventKindMessage.rawValue:
            do {
                delegate?.terminalSession(self, didReceive: try CmxWireCodec.decodeServerMessage(data))
            } catch {
                delegate?.terminalSession(self, didFail: error)
            }
        case CmxIrohClientEventKindClosed.rawValue:
            stopHeartbeat()
            disconnectTransport()
            if !closedByClient {
                delegate?.terminalSessionDidClose(self)
            }
        case CmxIrohClientEventKindError.rawValue:
            let message = String(data: data, encoding: .utf8) ?? ""
            stopHeartbeat()
            disconnectTransport()
            if !closedByClient {
                delegate?.terminalSession(self, didFail: CmxIrohTerminalSessionError.remoteError(message))
            }
        default:
            stopHeartbeat()
            disconnectTransport()
            if !closedByClient {
                delegate?.terminalSession(self, didFail: CmxIrohTerminalSessionError.unknownEvent)
            }
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
    Task { @MainActor in
        session.handleEvent(kind: kind, data: payload)
    }
}

enum CmxIrohTerminalSessionError: LocalizedError, Equatable {
    case failedToStart
    case sendFailed
    case remoteError(String)
    case unknownEvent

    var errorDescription: String? {
        switch self {
        case .failedToStart:
            String(localized: "iroh.error.start", defaultValue: "Could not start the iroh terminal session.")
        case .sendFailed:
            String(localized: "iroh.error.send", defaultValue: "Could not send data to the iroh terminal session.")
        case .remoteError(let message):
            String(
                format: String(localized: "iroh.error.remote", defaultValue: "Iroh connection failed: %@"),
                message.isEmpty ? String(localized: "iroh.error.remote_unknown", defaultValue: "unknown error") : message
            )
        case .unknownEvent:
            String(localized: "iroh.error.unknown_event", defaultValue: "The iroh terminal session sent an unknown event.")
        }
    }
}
