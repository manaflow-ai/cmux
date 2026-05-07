#if DEBUG
import Foundation

@MainActor
final class CmxUITestingEchoTerminalSession: CmxTerminalSession {
    weak var delegate: CmxTerminalSessionDelegate?

    private let usesPaletteTheme: Bool
    private var workspaces: [CmxUITestingEchoWorkspace]
    private var activeWorkspaceIndex = 0
    private var nextWorkspaceID: UInt64 = 10
    private var nextSpaceID: UInt64 = 100
    private var nextTerminalID: UInt64 = 1_000
    private var lastNativeLayoutByTerminalID: [UInt64: CmxTerminalSize] = [:]

    init() {
        let usesPaletteTheme = ProcessInfo.processInfo.environment["CMUX_IOS_UI_TESTING_PALETTE_SESSION"] == "1"
        self.usesPaletteTheme = usesPaletteTheme
        self.workspaces = CmxUITestingEchoWorkspace.defaultWorkspaces(
            promptBytes: usesPaletteTheme
                ? Data("\u{001B}[38;5;118mpalette-test$ \u{001B}[0m".utf8)
                : Data("\u{001B}[38;2;166;226;46mui-test$ \u{001B}[0m".utf8)
        )
    }

    func start(viewport: CmxWireViewport) {
        delegate?.terminalSession(self, didReceive: .welcome(serverVersion: "ui-test", sessionID: "ui-test"))
        emitNativeSnapshot()
        emitReplay(terminalID: activeTerminal.id)
    }

    func sendInput(_ data: Data, terminalID: UInt64) {
        guard let terminal = terminalState(for: terminalID) else { return }
        var pendingPrintableInput = Data()

        func flushPendingPrintableInput() {
            guard !pendingPrintableInput.isEmpty else { return }
            appendPrintableInput(pendingPrintableInput, terminal: terminal)
            pendingPrintableInput.removeAll(keepingCapacity: true)
        }

        for byte in data {
            switch byte {
            case 0x0A, 0x0D, 0x7F:
                flushPendingPrintableInput()
                handleInput(byte, terminal: terminal)
            default:
                pendingPrintableInput.append(byte)
            }
        }
        flushPendingPrintableInput()
    }

    private func appendPrintableInput(_ data: Data, terminal: CmxUITestingEchoTerminal) {
        let text = String(decoding: data, as: UTF8.self)
        if terminal.isAltScreen {
            terminal.altCommandLine.append(contentsOf: text)
        } else {
            terminal.commandLine.append(contentsOf: text)
        }
        appendAndEmit(data, terminal: terminal)
    }

    private func handleInput(_ byte: UInt8, terminal: CmxUITestingEchoTerminal) {
        if terminal.isAltScreen {
            handleAltScreenInput(byte, terminal: terminal)
            return
        }

        switch byte {
        case 0x0A, 0x0D:
            appendAndEmit(Data("\r\n".utf8), terminal: terminal)
            let shouldPrompt = emitCommandResult(terminal: terminal)
            terminal.commandLine.removeAll(keepingCapacity: true)
            if shouldPrompt {
                appendAndEmit(promptBytes, terminal: terminal)
            }
        case 0x7F:
            if !terminal.commandLine.isEmpty {
                terminal.commandLine.removeLast()
                appendAndEmit(Data("\u{8} \u{8}".utf8), terminal: terminal)
            }
        default:
            appendPrintableInput(Data([byte]), terminal: terminal)
        }
    }

    func sendResize(_: CmxWireViewport, terminalID _: UInt64) {}

    func sendNativeLayout(_ terminals: [CmxWireTerminalViewport]) {
        for terminal in terminals where terminal.cols > 0 && terminal.rows > 0 {
            lastNativeLayoutByTerminalID[terminal.tabID] = CmxTerminalSize(
                cols: Int(terminal.cols),
                rows: Int(terminal.rows)
            )
        }
    }

    func requestPtyReplay(terminalID: UInt64) {
        emitReplay(terminalID: terminalID)
    }

    func sendCommand(_ command: CmxClientCommand) {
        switch command {
        case .selectWorkspace(let index):
            guard workspaces.indices.contains(index) else { return }
            activeWorkspaceIndex = index
            emitNativeSnapshot()
            emitReplay(terminalID: activeTerminal.id)
        case .selectSpace(let index):
            let workspace = activeWorkspace
            guard workspace.spaces.indices.contains(index) else { return }
            workspace.activeSpaceIndex = index
            emitNativeSnapshot()
            emitReplay(terminalID: activeTerminal.id)
        case .selectTabInPanel(_, let index):
            let space = activeSpace
            guard space.terminals.indices.contains(index) else { return }
            space.activeTerminalIndex = index
            emitNativeSnapshot()
            emitReplay(terminalID: activeTerminal.id)
        case .setWorkspacePinned(let workspaceID, let pinned):
            guard let workspace = workspaceState(for: workspaceID) else { return }
            workspace.pinned = pinned
            emitNativeSnapshot()
        case .setWorkspaceUnread(let workspaceID, let unread):
            guard let workspace = workspaceState(for: workspaceID) else { return }
            workspace.hasActivity = unread
            emitNativeSnapshot()
        }
    }

    func disconnect() {
        delegate?.terminalSessionDidClose(self)
    }

    private func handleAltScreenInput(_ byte: UInt8, terminal: CmxUITestingEchoTerminal) {
        switch byte {
        case 0x0A, 0x0D:
            appendAndEmit(Data("\r\n".utf8), terminal: terminal)
            let command = terminal.altCommandLine.trimmingCharacters(in: .whitespacesAndNewlines)
            terminal.altCommandLine.removeAll(keepingCapacity: true)
            if command == ":q" || command == ":qa" || command == ":wq" {
                terminal.isAltScreen = false
                appendAndEmit(
                    Data("\u{001B}[?1049lalt screen exited\r\n".utf8) + promptBytes,
                    terminal: terminal
                )
            }
        case 0x7F:
            if !terminal.altCommandLine.isEmpty {
                terminal.altCommandLine.removeLast()
                appendAndEmit(Data("\u{8} \u{8}".utf8), terminal: terminal)
            }
        default:
            guard let scalar = UnicodeScalar(Int(byte)) else { return }
            terminal.altCommandLine.append(Character(scalar))
            appendAndEmit(Data([byte]), terminal: terminal)
        }
    }

    @discardableResult
    private func emitCommandResult(terminal: CmxUITestingEchoTerminal) -> Bool {
        let trimmed = terminal.commandLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }

        if trimmed.hasPrefix("echo ") {
            let output = String(trimmed.dropFirst(5))
            appendAndEmit(Data((output + "\r\n").utf8), terminal: terminal)
            return true
        }

        if trimmed == "clear" {
            terminal.output = Data("\u{001B}[2J\u{001B}[H".utf8)
            emitReplay(terminalID: terminal.id)
            return true
        }

        if trimmed == "vim" || trimmed == "nvim" || trimmed.hasPrefix("vim ") || trimmed.hasPrefix("nvim ") {
            terminal.isAltScreen = true
            terminal.altCommandLine.removeAll(keepingCapacity: true)
            appendAndEmit(
                Data(
                    """
                    \u{001B}[?1049h\u{001B}[2J\u{001B}[H\(trimmed.uppercased()) LONG-HAUL BUFFER
                    Type :q to exit. terminal=\(terminal.id)

                    """.utf8
                ),
                terminal: terminal
            )
            return false
        }

        if trimmed.hasPrefix("cmx rename workspace ") {
            let name = String(trimmed.dropFirst("cmx rename workspace ".count)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                activeWorkspace.title = name
                emitNativeSnapshot()
                appendAndEmit(Data(("renamed workspace \(name)\r\n").utf8), terminal: terminal)
            }
            return true
        }

        if trimmed.hasPrefix("cmx new-workspace ") {
            let name = String(trimmed.dropFirst("cmx new-workspace ".count)).trimmingCharacters(in: .whitespaces)
            createWorkspace(title: name.isEmpty ? "workspace-\(nextWorkspaceID)" : name)
            emitNativeSnapshot()
            emitReplay(terminalID: activeTerminal.id)
            return false
        }

        if trimmed.hasPrefix("cmx new-space ") {
            let name = String(trimmed.dropFirst("cmx new-space ".count)).trimmingCharacters(in: .whitespaces)
            createSpace(title: name.isEmpty ? "space-\(nextSpaceID)" : name)
            emitNativeSnapshot()
            emitReplay(terminalID: activeTerminal.id)
            return false
        }

        if trimmed.hasPrefix("cmx new-tab ") || trimmed.hasPrefix("cmx new-terminal ") {
            let prefix = trimmed.hasPrefix("cmx new-tab ") ? "cmx new-tab " : "cmx new-terminal "
            let name = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            createTerminal(title: name.isEmpty ? "term-\(nextTerminalID)" : name)
            emitNativeSnapshot()
            emitReplay(terminalID: activeTerminal.id)
            return false
        }

        if trimmed == "cmx move-workspace next" || trimmed == "cmx move-workspace prev" {
            moveActiveWorkspace(forward: trimmed.hasSuffix("next"))
            emitNativeSnapshot()
            emitReplay(terminalID: activeTerminal.id)
            return false
        }

        if trimmed.hasPrefix("cmux-stress-burst ") {
            emitStressBurst(command: trimmed, terminal: terminal)
            return true
        }

        appendAndEmit(Data(("ran: \(trimmed)\r\n").utf8), terminal: terminal)
        return true
    }

    private func emitStressBurst(command: String, terminal: CmxUITestingEchoTerminal) {
        let parts = command.split(separator: " ")
        let count = parts.dropFirst().first.flatMap { Int($0) } ?? 64
        let label = parts.dropFirst(2).first.map(String.init) ?? "burst"
        var output = Data()
        for index in 0..<max(1, min(count, 512)) {
            output.append(
                contentsOf: "\u{001B}[3\((index % 6) + 1)m\(label) line \(index) \(String(repeating: "#", count: index % 32))\u{001B}[0m\r\n".utf8
            )
        }
        appendAndEmit(output, terminal: terminal)
    }

    private func createWorkspace(title: String) {
        let terminal = CmxUITestingEchoTerminal(
            id: nextTerminalID,
            title: "shell",
            output: initialOutput(title: title, terminalID: nextTerminalID)
        )
        nextTerminalID += 1
        let space = CmxUITestingEchoSpace(id: nextSpaceID, title: "space-1", terminals: [terminal])
        nextSpaceID += 1
        let workspace = CmxUITestingEchoWorkspace(id: nextWorkspaceID, title: title, spaces: [space])
        nextWorkspaceID += 1
        workspaces.append(workspace)
        activeWorkspaceIndex = workspaces.count - 1
    }

    private func createSpace(title: String) {
        let terminal = CmxUITestingEchoTerminal(
            id: nextTerminalID,
            title: "shell",
            output: initialOutput(title: title, terminalID: nextTerminalID)
        )
        nextTerminalID += 1
        let space = CmxUITestingEchoSpace(id: nextSpaceID, title: title, terminals: [terminal])
        nextSpaceID += 1
        activeWorkspace.spaces.append(space)
        activeWorkspace.activeSpaceIndex = activeWorkspace.spaces.count - 1
    }

    private func createTerminal(title: String) {
        let terminal = CmxUITestingEchoTerminal(
            id: nextTerminalID,
            title: title,
            output: initialOutput(title: title, terminalID: nextTerminalID)
        )
        nextTerminalID += 1
        activeSpace.terminals.append(terminal)
        activeSpace.activeTerminalIndex = activeSpace.terminals.count - 1
    }

    private func moveActiveWorkspace(forward: Bool) {
        guard workspaces.count > 1 else { return }
        let oldIndex = activeWorkspaceIndex
        let newIndex = forward ? min(oldIndex + 1, workspaces.count - 1) : max(oldIndex - 1, 0)
        guard oldIndex != newIndex else { return }
        workspaces.swapAt(oldIndex, newIndex)
        activeWorkspaceIndex = newIndex
    }

    private func emitNativeSnapshot() {
        delegate?.terminalSession(self, didReceive: .nativeSnapshot(nativeSnapshot()))
    }

    private func emitReplay(terminalID: UInt64) {
        guard let terminal = terminalState(for: terminalID) else { return }
        delegate?.terminalSession(self, didReceive: .ptyBytes(tabID: terminal.id, data: terminal.output))
    }

    private func appendAndEmit(_ data: Data, terminal: CmxUITestingEchoTerminal) {
        terminal.output.append(data)
        terminal.trimReplayBufferIfNeeded()
        delegate?.terminalSession(self, didReceive: .ptyBytes(tabID: terminal.id, data: data))
    }

    private var activeWorkspace: CmxUITestingEchoWorkspace {
        workspaces[max(0, min(activeWorkspaceIndex, workspaces.count - 1))]
    }

    private var activeSpace: CmxUITestingEchoSpace {
        let workspace = activeWorkspace
        return workspace.spaces[max(0, min(workspace.activeSpaceIndex, workspace.spaces.count - 1))]
    }

    private var activeTerminal: CmxUITestingEchoTerminal {
        let space = activeSpace
        return space.terminals[max(0, min(space.activeTerminalIndex, space.terminals.count - 1))]
    }

    private func workspaceState(for id: UInt64) -> CmxUITestingEchoWorkspace? {
        workspaces.first { $0.id == id }
    }

    private func terminalState(for id: UInt64) -> CmxUITestingEchoTerminal? {
        for workspace in workspaces {
            for space in workspace.spaces {
                if let terminal = space.terminals.first(where: { $0.id == id }) {
                    return terminal
                }
            }
        }
        return nil
    }

    private func nativeSnapshot() -> CmxNativeSnapshot {
        let workspace = activeWorkspace
        let space = activeSpace
        return CmxNativeSnapshot(
            workspaces: workspaces.map { workspace in
                CmxNativeWorkspaceInfo(
                    id: workspace.id,
                    title: workspace.title,
                    spaceCount: workspace.spaces.count,
                    tabCount: workspace.spaces.reduce(0) { $0 + $1.terminals.count },
                    terminalCount: workspace.spaces.reduce(0) { $0 + $1.terminals.count },
                    pinned: workspace.pinned,
                    hasActivity: workspace.hasActivity,
                    color: nil
                )
            },
            activeWorkspace: activeWorkspaceIndex,
            activeWorkspaceID: workspace.id,
            spaces: workspace.spaces.map { space in
                CmxNativeSpaceInfo(
                    id: space.id,
                    title: space.title,
                    paneCount: 1,
                    terminalCount: space.terminals.count
                )
            },
            activeSpace: workspace.activeSpaceIndex,
            activeSpaceID: space.id,
            panels: .leaf(
                panelID: space.panelID,
                tabs: space.terminals.map { terminal in
                    CmxNativeTabInfo(
                        id: terminal.id,
                        title: terminal.title,
                        hasActivity: terminal.hasActivity,
                        bellCount: UInt64(terminal.bellCount)
                    )
                },
                active: space.activeTerminalIndex,
                activeTabID: activeTerminal.id
            ),
            focusedPanelID: space.panelID,
            focusedTabID: activeTerminal.id,
            attachedClients: [
                CmxAttachedClientInfo(
                    clientID: "ui-peer",
                    kind: .native,
                    visibleTerminalCount: lastNativeLayoutByTerminalID.count,
                    updatedAtMilliseconds: 0,
                    terminals: lastNativeLayoutByTerminalID.map { terminalID, size in
                        CmxWireTerminalViewport(
                            tabID: terminalID,
                            cols: UInt16(clamping: size.cols),
                            rows: UInt16(clamping: size.rows)
                        )
                    },
                    latencyMilliseconds: nil
                ),
            ],
            terminalTheme: usesPaletteTheme ? Self.paletteTheme : nil
        )
    }

    private var promptBytes: Data {
        if usesPaletteTheme {
            return Data("\u{001B}[38;5;118mpalette-test$ \u{001B}[0m".utf8)
        }
        return Data("\u{001B}[38;2;166;226;46mui-test$ \u{001B}[0m".utf8)
    }

    private func initialOutput(title: String, terminalID: UInt64) -> Data {
        Data("\u{001B}[2J\u{001B}[H\(title) terminal \(terminalID)\r\n".utf8) + promptBytes
    }

    private static let paletteTheme = CmxNativeTerminalThemeSet(
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
}

private final class CmxUITestingEchoWorkspace {
    let id: UInt64
    var title: String
    var pinned: Bool
    var hasActivity: Bool
    var spaces: [CmxUITestingEchoSpace]
    var activeSpaceIndex: Int

    init(
        id: UInt64,
        title: String,
        pinned: Bool = false,
        hasActivity: Bool = false,
        spaces: [CmxUITestingEchoSpace],
        activeSpaceIndex: Int = 0
    ) {
        self.id = id
        self.title = title
        self.pinned = pinned
        self.hasActivity = hasActivity
        self.spaces = spaces
        self.activeSpaceIndex = activeSpaceIndex
    }

    static func defaultWorkspaces(promptBytes: Data) -> [CmxUITestingEchoWorkspace] {
        [
            workspace(id: 1, title: "main", terminalBaseID: 100, promptBytes: promptBytes, pinned: true),
            workspace(id: 2, title: "ios-sync-ws", terminalBaseID: 200, promptBytes: promptBytes),
            workspace(id: 3, title: "bd34-sync", terminalBaseID: 300, promptBytes: promptBytes),
        ]
    }

    private static func workspace(
        id: UInt64,
        title: String,
        terminalBaseID: UInt64,
        promptBytes: Data,
        pinned: Bool = false
    ) -> CmxUITestingEchoWorkspace {
        let first = CmxUITestingEchoTerminal(
            id: terminalBaseID,
            title: "shell",
            output: Data("\u{001B}[2J\u{001B}[H\(title) terminal \(terminalBaseID)\r\n".utf8) + promptBytes
        )
        let second = CmxUITestingEchoTerminal(
            id: terminalBaseID + 1,
            title: "logs",
            output: Data("\u{001B}[2J\u{001B}[H\(title) logs \(terminalBaseID + 1)\r\n".utf8) + promptBytes
        )
        return CmxUITestingEchoWorkspace(
            id: id,
            title: title,
            pinned: pinned,
            spaces: [
                CmxUITestingEchoSpace(id: id * 10, title: "space-1", terminals: [first, second]),
                CmxUITestingEchoSpace(
                    id: id * 10 + 1,
                    title: "scratch",
                    terminals: [
                        CmxUITestingEchoTerminal(
                            id: terminalBaseID + 2,
                            title: "scratch",
                            output: Data("\u{001B}[2J\u{001B}[H\(title) scratch \(terminalBaseID + 2)\r\n".utf8)
                                + promptBytes
                        ),
                    ]
                ),
            ]
        )
    }
}

private final class CmxUITestingEchoSpace {
    let id: UInt64
    var title: String
    var terminals: [CmxUITestingEchoTerminal]
    var activeTerminalIndex: Int

    init(id: UInt64, title: String, terminals: [CmxUITestingEchoTerminal], activeTerminalIndex: Int = 0) {
        self.id = id
        self.title = title
        self.terminals = terminals
        self.activeTerminalIndex = activeTerminalIndex
    }

    var panelID: UInt64 {
        id + 10_000
    }
}

private final class CmxUITestingEchoTerminal {
    let id: UInt64
    var title: String
    var hasActivity: Bool
    var bellCount: Int
    var output: Data
    var commandLine = ""
    var isAltScreen = false
    var altCommandLine = ""

    init(id: UInt64, title: String, hasActivity: Bool = false, bellCount: Int = 0, output: Data) {
        self.id = id
        self.title = title
        self.hasActivity = hasActivity
        self.bellCount = bellCount
        self.output = output
    }

    func trimReplayBufferIfNeeded() {
        let maximumBytes = 128 * 1_024
        guard output.count > maximumBytes else { return }
        output.removeFirst(output.count - maximumBytes)
        output = Data("\u{001B}[2J\u{001B}[H[replay truncated]\r\n".utf8) + output
    }
}
#endif
