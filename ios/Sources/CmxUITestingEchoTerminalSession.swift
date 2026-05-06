#if DEBUG
import Foundation

@MainActor
final class CmxUITestingEchoTerminalSession: CmxTerminalSession {
    weak var delegate: CmxTerminalSessionDelegate?

    private var commandLine = ""
    private let usesPaletteTheme = ProcessInfo.processInfo.environment["CMUX_IOS_UI_TESTING_PALETTE_SESSION"] == "1"
    private static let echoTerminalID: UInt64 = 100

    func start(viewport: CmxWireViewport) {
        delegate?.terminalSession(self, didReceive: .welcome(serverVersion: "ui-test", sessionID: "ui-test"))
        if usesPaletteTheme {
            delegate?.terminalSession(self, didReceive: .nativeSnapshot(Self.paletteSnapshot))
        } else {
            delegate?.terminalSession(self, didReceive: .nativeSnapshot(Self.echoSnapshot))
        }
        emit(
            Data("\u{001B}[2J\u{001B}[H".utf8) + promptBytes,
            terminalID: Self.echoTerminalID
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
    func requestPtyReplay(terminalID: UInt64) {
        emit(
            Data("\u{001B}[2J\u{001B}[H".utf8) + promptBytes,
            terminalID: terminalID
        )
    }
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
        workspaces: CmxUITestingEchoTerminalSession.echoWorkspaces,
        activeWorkspace: 0,
        activeWorkspaceID: 1,
        spaces: CmxUITestingEchoTerminalSession.echoSpaces,
        activeSpace: 0,
        activeSpaceID: 10,
        panels: CmxUITestingEchoTerminalSession.echoPanel(title: "palette"),
        focusedPanelID: 31,
        focusedTabID: CmxUITestingEchoTerminalSession.echoTerminalID,
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

    private static let echoSnapshot = CmxNativeSnapshot(
        workspaces: CmxUITestingEchoTerminalSession.echoWorkspaces,
        activeWorkspace: 0,
        activeWorkspaceID: 1,
        spaces: CmxUITestingEchoTerminalSession.echoSpaces,
        activeSpace: 0,
        activeSpaceID: 10,
        panels: CmxUITestingEchoTerminalSession.echoPanel(title: "echo"),
        focusedPanelID: 31,
        focusedTabID: CmxUITestingEchoTerminalSession.echoTerminalID
    )

    private static let echoWorkspaces = [
        CmxNativeWorkspaceInfo(
            id: 1,
            title: "main",
            spaceCount: 1,
            tabCount: 1,
            terminalCount: 1,
            pinned: true,
            color: nil
        ),
    ]

    private static let echoSpaces = [
        CmxNativeSpaceInfo(
            id: 10,
            title: "space-1",
            paneCount: 1,
            terminalCount: 1
        ),
    ]

    private static func echoPanel(title: String) -> CmxNativePanelNode {
        .leaf(
            panelID: 31,
            tabs: [
                CmxNativeTabInfo(
                    id: CmxUITestingEchoTerminalSession.echoTerminalID,
                    title: title,
                    hasActivity: false,
                    bellCount: 0
                ),
            ],
            active: 0,
            activeTabID: CmxUITestingEchoTerminalSession.echoTerminalID
        )
    }
}
#endif
