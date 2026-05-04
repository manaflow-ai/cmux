import Foundation

@MainActor
protocol CmxTerminalSessionDelegate: AnyObject {
    func terminalSession(_ session: any CmxTerminalSession, didReceive message: CmxServerMessage)
    func terminalSession(_ session: any CmxTerminalSession, didFail error: Error)
    func terminalSessionDidClose(_ session: any CmxTerminalSession)
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
