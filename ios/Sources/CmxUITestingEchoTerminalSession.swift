#if DEBUG
import Foundation

@MainActor
final class CmxUITestingEchoTerminalSession: CmxTerminalSession {
    weak var delegate: CmxTerminalSessionDelegate?

    private var commandLine = ""

    func start(viewport: CmxWireViewport) {
        delegate?.terminalSession(self, didReceive: .welcome(serverVersion: "ui-test", sessionID: "ui-test"))
        emit(
            Data(
                "\u{001B}[2J\u{001B}[H\u{001B}[38;2;166;226;46mui-test$ \u{001B}[0m".utf8
            ),
            terminalID: CmxDemoState.workspaces[0].spaces[0].terminals[0].id
        )
    }

    func sendInput(_ data: Data, terminalID: UInt64) {
        for byte in data {
            switch byte {
            case 0x0A, 0x0D:
                emit(Data("\r\n".utf8), terminalID: terminalID)
                emitCommandResult(terminalID: terminalID)
                commandLine.removeAll(keepingCapacity: true)
                emit(Data("\u{001B}[38;2;166;226;46mui-test$ \u{001B}[0m".utf8), terminalID: terminalID)
            case 0x7F:
                if !commandLine.isEmpty {
                    commandLine.removeLast()
                    emit(Data("\u{8} \u{8}".utf8), terminalID: terminalID)
                }
            default:
                guard let scalar = UnicodeScalar(Int(byte)) else { continue }
                commandLine.append(Character(scalar))
                emit(Data([byte]), terminalID: terminalID)
            }
        }
    }

    func sendResize(_ viewport: CmxWireViewport, terminalID: UInt64) {}
    func sendNativeLayout(_ terminals: [CmxWireTerminalViewport]) {}
    func sendCommand(_ command: CmxClientCommand) {}
    func disconnect() {
        delegate?.terminalSessionDidClose(self)
    }

    private func emitCommandResult(terminalID: UInt64) {
        let trimmed = commandLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("echo ") else { return }
        let output = String(trimmed.dropFirst(5))
        emit(Data((output + "\r\n").utf8), terminalID: terminalID)
    }

    private func emit(_ data: Data, terminalID: UInt64) {
        delegate?.terminalSession(self, didReceive: .ptyBytes(tabID: terminalID, data: data))
    }
}
#endif
