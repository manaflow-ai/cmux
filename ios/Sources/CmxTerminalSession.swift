import Foundation

@MainActor
protocol CmxTerminalSessionDelegate: AnyObject {
    func terminalSession(_ session: any CmxTerminalSession, didReceive message: CmxServerMessage)
    func terminalSession(_ session: any CmxTerminalSession, didUpdateLatencyMilliseconds latencyMilliseconds: UInt32)
    func terminalSession(_ session: any CmxTerminalSession, didFail error: Error)
    func terminalSessionDidClose(_ session: any CmxTerminalSession)
}

extension CmxTerminalSessionDelegate {
    func terminalSession(_ session: any CmxTerminalSession, didUpdateLatencyMilliseconds latencyMilliseconds: UInt32) {}
}

@MainActor
protocol CmxTerminalSession: AnyObject {
    var delegate: CmxTerminalSessionDelegate? { get set }

    func start(viewport: CmxWireViewport)
    func sendInput(_ data: Data, terminalID: UInt64)
    func sendResize(_ viewport: CmxWireViewport, terminalID: UInt64)
    func sendNativeLayout(_ terminals: [CmxWireTerminalViewport])
    func sendCommand(_ command: CmxClientCommand)
    func disconnect()
}

enum CmxHeartbeatAction: Equatable {
    case sendPing
    case waitForPong
    case timedOut(elapsedSeconds: TimeInterval)
}

struct CmxHeartbeatState {
    var pendingPingSentAt: Date?
    let timeout: TimeInterval

    init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    mutating func tick(now: Date = Date()) -> CmxHeartbeatAction {
        guard let pendingPingSentAt else {
            self.pendingPingSentAt = now
            return .sendPing
        }
        let elapsed = now.timeIntervalSince(pendingPingSentAt)
        if elapsed >= timeout {
            return .timedOut(elapsedSeconds: elapsed)
        }
        return .waitForPong
    }

    mutating func recordPong(now: Date = Date()) -> UInt32? {
        guard let pendingPingSentAt else { return nil }
        self.pendingPingSentAt = nil
        let elapsedMilliseconds = max(0, now.timeIntervalSince(pendingPingSentAt) * 1_000)
        return UInt32(clamping: Int(elapsedMilliseconds.rounded()))
    }

    mutating func reset() {
        pendingPingSentAt = nil
    }
}

@MainActor
protocol CmxTerminalSessionMaking {
    func makeSession(
        rawTicket: String,
        ticket: CmxBridgeTicket,
        pairingSecret: String?,
        stackAuthSession: CmxStackAuthSession?
    ) throws -> any CmxTerminalSession
}

@MainActor
struct CmxDefaultTerminalSessionFactory: CmxTerminalSessionMaking {
    nonisolated init() {}

    func makeSession(
        rawTicket: String,
        ticket: CmxBridgeTicket,
        pairingSecret: String?,
        stackAuthSession: CmxStackAuthSession?
    ) throws -> any CmxTerminalSession {
        #if DEBUG
        if CmxLaunchConfiguration.usesUITestingEchoSession() {
            return CmxUITestingEchoTerminalSession()
        }
        #endif

        if let webSocketURL = ticket.webSocketURL {
            return CmxWebSocketTerminalSession(
                url: webSocketURL,
                token: ticket.webSocketToken,
                headers: ticket.auth?.requiresStackSession == true ? stackAuthSession?.authorizationHeaders ?? [:] : [:]
            )
        }

        return CmxIrohTerminalSession(
            ticket: rawTicket,
            pairingSecret: pairingSecret
        )
    }
}
