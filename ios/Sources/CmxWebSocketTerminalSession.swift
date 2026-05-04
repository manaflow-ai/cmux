import Foundation

@MainActor
final class CmxWebSocketTerminalSession: CmxTerminalSession {
    private static let heartbeatInterval: TimeInterval = 5

    enum Mode: Equatable {
        case tui
        case nativeLibghostty
    }

    weak var delegate: CmxTerminalSessionDelegate?

    private let url: URL
    private let token: String?
    private let mode: Mode
    private let headers: [String: String]
    private let urlSession: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTimer: Timer?
    private var closedByClient = false
    private var nextCommandID: UInt32 = 1

    init(
        url: URL,
        token: String?,
        mode: Mode = .nativeLibghostty,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.url = url
        self.token = token
        self.mode = mode
        self.headers = headers
        self.urlSession = urlSession
    }

    func start(viewport: CmxWireViewport) {
        closedByClient = false
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = urlSession.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        switch mode {
        case .tui:
            send(.hello(viewport: viewport, token: token))
        case .nativeLibghostty:
            send(.helloNative(viewport: viewport, token: token))
        }
        startHeartbeat()
    }

    func sendInput(_ data: Data, terminalID: UInt64) {
        switch mode {
        case .tui:
            send(.input(data))
        case .nativeLibghostty:
            send(.nativeInput(tabID: terminalID, data: data))
        }
    }

    func sendResize(_ viewport: CmxWireViewport, terminalID: UInt64) {
        switch mode {
        case .tui:
            send(.resize(viewport))
        case .nativeLibghostty:
            send(.nativeLayout([
                CmxWireTerminalViewport(tabID: terminalID, cols: viewport.cols, rows: viewport.rows),
            ]))
        }
    }

    func sendNativeLayout(_ terminals: [CmxWireTerminalViewport]) {
        send(.nativeLayout(terminals))
    }

    func sendCommand(_ command: CmxClientCommand) {
        let id = nextCommandID
        nextCommandID = nextCommandID == UInt32.max ? 1 : nextCommandID + 1
        send(.command(id: id, command))
    }

    func sendPing() {
        send(.ping)
    }

    func disconnect() {
        closedByClient = true
        stopHeartbeat()
        receiveTask?.cancel()
        receiveTask = nil
        send(.detach)
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func send(_ message: CmxClientMessage) {
        guard let task else { return }
        do {
            let payload = try CmxWireCodec.encode(message)
            task.send(.data(payload)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    guard let self, !self.closedByClient else { return }
                    self.delegate?.terminalSession(self, didFail: error)
                }
            }
        } catch {
            delegate?.terminalSession(self, didFail: error)
        }
    }

    private func receiveLoop() async {
        guard let task else { return }
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                switch message {
                case .data(let payload):
                    let decoded = try CmxWireCodec.decodeServerMessage(payload)
                    if case .bye = decoded {
                        stopHeartbeat()
                    }
                    delegate?.terminalSession(self, didReceive: decoded)
                case .string:
                    throw CmxWebSocketTerminalSessionError.unexpectedTextFrame
                @unknown default:
                    throw CmxWebSocketTerminalSessionError.unsupportedFrame
                }
            }
        } catch {
            stopHeartbeat()
            guard !closedByClient else { return }
            delegate?.terminalSession(self, didFail: error)
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        send(.ping)
        let timer = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.task != nil, !self.closedByClient else { return }
                self.send(.ping)
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

enum CmxWebSocketTerminalSessionError: LocalizedError {
    case unexpectedTextFrame
    case unsupportedFrame

    var errorDescription: String? {
        switch self {
        case .unexpectedTextFrame:
            String(localized: "ticket.error.websocket_text", defaultValue: "cmx sent an unexpected WebSocket text frame.")
        case .unsupportedFrame:
            String(localized: "ticket.error.websocket_frame", defaultValue: "cmx sent an unsupported WebSocket frame.")
        }
    }
}
