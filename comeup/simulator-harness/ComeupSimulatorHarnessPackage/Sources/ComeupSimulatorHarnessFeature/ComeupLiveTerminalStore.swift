import Combine
import Foundation
import Network

public struct ComeupTerminalOutputChunk: Identifiable, Equatable, Sendable {
    public var id: Int
    public var data: Data
}

@MainActor
public final class ComeupLiveTerminalStore: ObservableObject, GhosttyTerminalSurfaceViewDelegate {
    public enum ConnectionState: Equatable, Sendable {
        case disabled
        case connecting
        case connected
        case failed(String)
    }

    @Published public private(set) var state: ConnectionState = .disabled
    @Published public private(set) var terminalID: Int?
    @Published public private(set) var size: CmuxTerminalSize
    @Published public private(set) var outputChunks: [ComeupTerminalOutputChunk] = []
    @Published public private(set) var accessibilityText = ""

    private let port: UInt16?
    private let authToken: String?
    private let sendOnConnect: String?
    private let queue = DispatchQueue(label: "ComeupLiveTerminalStore.connection")
    private var connection: NWConnection?
    private var lineBuffer = Data()
    private var nextOutputID = 0
    private var hasStarted = false
    private var didSendOnConnect = false

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultSize: CmuxTerminalSize = CmuxTerminalSize(cols: 66, rows: 18)
    ) {
        let portText = environment["COMEUP_TEXT_PORT"] ?? environment["TEST_RUNNER_COMEUP_TEXT_PORT"]
        self.port = portText.flatMap(UInt16.init)
        let authTokenText = environment["COMEUP_AUTH_TOKEN"] ?? environment["TEST_RUNNER_COMEUP_AUTH_TOKEN"]
        self.authToken = authTokenText.flatMap { $0.isEmpty ? nil : $0 }
        self.sendOnConnect = environment["COMEUP_SEND_ON_CONNECT"]
        self.size = defaultSize
        self.state = port == nil ? .disabled : .connecting
    }

    public var isEnabled: Bool {
        port != nil
    }

    deinit {
        connection?.cancel()
    }

    public func connectIfNeeded() {
        guard !hasStarted, let port else { return }
        hasStarted = true
        state = .connecting

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            state = .failed("invalid port")
            return
        }

        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }
        connection.start(queue: queue)
    }

    public func ghosttyTerminalSurfaceView(_ surfaceView: GhosttyTerminalSurfaceView, didProduceInput data: Data) {
        sendInput(data)
    }

    public func ghosttyTerminalSurfaceView(_ surfaceView: GhosttyTerminalSurfaceView, didResize size: TerminalGridSize) {
        self.size = CmuxTerminalSize(cols: size.columns, rows: size.rows)
        guard let terminalID else { return }
        sendLine("VISIBLE \(terminalID) \(size.columns) \(size.rows)")
    }

    public func sendInput(_ data: Data) {
        guard let terminalID, !data.isEmpty else { return }
        sendLine("SEND_HEX \(terminalID) \(Self.hexString(for: data))")
    }

    private func handleConnectionState(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            state = .connected
            sendLine(Self.helloLine(size: size, authToken: authToken))
            receiveNext()
        case .failed(let error):
            state = .failed(error.localizedDescription)
        case .cancelled:
            state = .disabled
        default:
            break
        }
    }

    nonisolated static func helloLine(size: CmuxTerminalSize, authToken: String?) -> String {
        var line = "HELLO \(size.cols) \(size.rows)"
        if let authToken, !authToken.isEmpty {
            line += " AUTH bearer \(authToken)"
        }
        return line
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.consume(data)
                }
                if let error {
                    self.state = .failed(error.localizedDescription)
                    return
                }
                if !isComplete {
                    self.receiveNext()
                }
            }
        }
    }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newlineIndex = lineBuffer.firstIndex(of: 10) {
            let lineData = lineBuffer[..<newlineIndex]
            lineBuffer.removeSubrange(...newlineIndex)
            handleLine(String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .newlines))
        }
    }

    private func handleLine(_ line: String) {
        if line.hasPrefix("WELCOME ") {
            handleWelcome(line)
        } else if line.hasPrefix("SIZE ") {
            handleSize(line)
        } else if line.hasPrefix("FOCUS terminal=") {
            terminalID = Int(line.dropFirst("FOCUS terminal=".count)) ?? terminalID
        } else if line.hasPrefix("OUTPUT ") {
            handleOutput(line)
        } else if line.hasPrefix("ERROR ") {
            state = .failed(String(line.dropFirst("ERROR ".count)))
        }
    }

    private func handleWelcome(_ line: String) {
        let fields = Self.keyValueFields(in: line)
        if let terminalText = fields["terminal"], let terminal = Int(terminalText) {
            terminalID = terminal
        }
        if let sizeText = fields["size"], let parsedSize = Self.parseSize(sizeText) {
            size = parsedSize
        }
        if let terminalID {
            sendLine("VISIBLE \(terminalID) \(size.cols) \(size.rows)")
        }
        sendConfiguredInputIfNeeded()
    }

    private func handleSize(_ line: String) {
        let pieces = line.split(separator: " ")
        guard pieces.count == 3,
              let terminalText = pieces[1].split(separator: "=").last,
              let terminal = Int(terminalText),
              terminal == terminalID || terminalID == nil,
              let parsedSize = Self.parseSize(String(pieces[2])) else { return }
        terminalID = terminal
        size = parsedSize
    }

    private func handleOutput(_ line: String) {
        let prefix = "OUTPUT terminal="
        guard line.hasPrefix(prefix) else { return }
        let rest = line.dropFirst(prefix.count)
        let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let terminal = Int(parts[0]),
              terminal == terminalID || terminalID == nil else { return }
        terminalID = terminal
        appendOutput(Self.decodeEscapedText(String(parts[1])))
    }

    private func appendOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        nextOutputID += 1
        outputChunks.append(ComeupTerminalOutputChunk(id: nextOutputID, data: data))
        accessibilityText.append(String(decoding: data, as: UTF8.self))
    }

    private func sendConfiguredInputIfNeeded() {
        guard !didSendOnConnect, let sendOnConnect else { return }
        didSendOnConnect = true
        sendInput(Data((sendOnConnect + "\n").utf8))
    }

    private func sendLine(_ line: String) {
        guard let connection else { return }
        connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.state = .failed(error.localizedDescription)
            }
        })
    }

    private static func keyValueFields(in line: String) -> [String: String] {
        var fields: [String: String] = [:]
        for piece in line.split(separator: " ") {
            let pair = piece.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            fields[String(pair[0])] = String(pair[1])
        }
        return fields
    }

    private static func parseSize(_ text: String) -> CmuxTerminalSize? {
        let pieces = text.split(separator: "x", maxSplits: 1)
        guard pieces.count == 2,
              let cols = Int(pieces[0]),
              let rows = Int(pieces[1]) else { return nil }
        return CmuxTerminalSize(cols: cols, rows: rows)
    }

    private static func decodeEscapedText(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        var decoded: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 92, index + 1 < bytes.count {
                switch bytes[index + 1] {
                case 110:
                    decoded.append(10)
                    index += 2
                    continue
                case 114:
                    decoded.append(13)
                    index += 2
                    continue
                case 92:
                    decoded.append(92)
                    index += 2
                    continue
                default:
                    break
                }
            }
            decoded.append(bytes[index])
            index += 1
        }
        return Data(decoded)
    }

    private static func hexString(for data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
