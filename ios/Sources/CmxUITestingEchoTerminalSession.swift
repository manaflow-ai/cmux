#if DEBUG
import Foundation

@MainActor
final class CmxUITestingEchoTerminalSession: CmxTerminalSession {
    weak var delegate: CmxTerminalSessionDelegate?

    private var commandLine = ""
    private let usesPaletteTheme = ProcessInfo.processInfo.environment["CMUX_IOS_UI_TESTING_PALETTE_SESSION"] == "1"

    func start(viewport: CmxWireViewport) {
        delegate?.terminalSession(self, didReceive: .welcome(serverVersion: "ui-test", sessionID: "ui-test"))
        if usesPaletteTheme {
            delegate?.terminalSession(self, didReceive: .nativeSnapshot(Self.paletteSnapshot))
        }
        emit(
            Data("\u{001B}[2J\u{001B}[H".utf8) + promptBytes,
            terminalID: CmxDemoState.workspaces.flatMap(\.spaces).flatMap(\.terminals).first?.id ?? 0
        )
    }

    func sendInput(_ data: Data, terminalID: UInt64) {
        for byte in data {
            switch byte {
            case 0x0A, 0x0D:
                emit(Data("\r\n".utf8), terminalID: terminalID)
                emitCommandResult(terminalID: terminalID)
                commandLine.removeAll(keepingCapacity: true)
                emit(promptBytes, terminalID: terminalID)
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

    private var promptBytes: Data {
        if usesPaletteTheme {
            return Data("\u{001B}[38;5;118mpalette-test$ \u{001B}[0m".utf8)
        }
        return Data("\u{001B}[38;2;166;226;46mui-test$ \u{001B}[0m".utf8)
    }

    private static let paletteSnapshot = CmxNativeSnapshot(
        workspaces: [
            CmxNativeWorkspaceInfo(
                id: 1,
                title: "main",
                spaceCount: 1,
                tabCount: 1,
                terminalCount: 1,
                pinned: true,
                color: nil
            ),
        ],
        activeWorkspace: 0,
        activeWorkspaceID: 1,
        spaces: [
            CmxNativeSpaceInfo(
                id: 10,
                title: "space-1",
                paneCount: 1,
                terminalCount: 1
            ),
        ],
        activeSpace: 0,
        activeSpaceID: 10,
        panels: .leaf(
            panelID: 31,
            tabs: [
                CmxNativeTabInfo(id: 100, title: "palette", hasActivity: false, bellCount: 0),
            ],
            active: 0,
            activeTabID: 100
        ),
        focusedPanelID: 31,
        focusedTabID: 100,
        terminalTheme: CmxNativeTerminalThemeSet(
            defaultTheme: CmxNativeTerminalTheme(
                palette: [118: "#FF00CC"],
                foreground: "#F5F5F5",
                background: "#020304",
                cursor: "#F5F5F5",
                cursorAccent: nil,
                selectionBackground: "#333333",
                selectionForeground: "#FFFFFF",
                black: nil,
                red: nil,
                green: nil,
                yellow: nil,
                blue: nil,
                magenta: nil,
                cyan: nil,
                white: nil,
                brightBlack: nil,
                brightRed: nil,
                brightGreen: nil,
                brightYellow: nil,
                brightBlue: nil,
                brightMagenta: nil,
                brightCyan: nil,
                brightWhite: nil
            ),
            light: nil,
            dark: nil
        )
    )
}
#endif
