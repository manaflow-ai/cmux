import CNCore
import CNTransport
import Foundation

extension MockEngine {
    func mutateTerminal(_ id: String, _ change: (inout MockTerminal) -> Void) throws {
        guard var t = terminals[id] else { throw notFound("terminal", id) }
        change(&t)
        terminals[id] = t
        broadcast(.termUpdated, TerminalResult(terminal: t.info))
    }

    func createTerminal(_ p: TerminalCreateParams) -> Terminal {
        var shell = MockShell()
        if let cwd = p.cwd { shell.directory = cwd }
        let info = Terminal(id: makeId("t"), title: "zsh", cwd: shell.directory, cols: p.cols, rows: p.rows, running: true, createdAt: now())
        var t = MockTerminal(info: info, mode: .shell, shell: shell)
        t.scrollback = Data(("Last login: \(MockShell.clock()) on ttys004\r\n" + shell.prompt).utf8)
        terminals[info.id] = t
        terminalOrder.append(info.id)
        broadcast(.termUpdated, TerminalResult(terminal: info))
        return info
    }

    func attachTerminal(_ p: TerminalAttachParams, session: MockServerSession) throws -> TerminalAttachResult {
        guard var t = terminals[p.terminalId] else { throw notFound("terminal", p.terminalId) }
        let streamId = allocateStream(for: session)
        terminalStreams[streamId] = t.info.id
        t.streams.insert(streamId)
        t.info.cols = p.cols
        t.info.rows = p.rows
        terminals[t.info.id] = t
        // Replay: scrollback first (frames may arrive before the response;
        // HostClient buffers them), then live output.
        var replay = t.scrollback
        if t.mode == .top {
            replay.append(Data(("\u{1B}[2J" + t.shell.topScreen(tick: t.tick, cols: t.info.cols, rows: t.info.rows)).utf8))
        }
        var offset = 0
        while offset < replay.count {
            let end = min(offset + 4096, replay.count)
            session.sendFrame(StreamFrame(kind: .termOutput, streamId: streamId, payload: replay.subdata(in: offset..<end)))
            offset = end
        }
        updateTerminalAnimation(t.info.id)
        return TerminalAttachResult(streamId: streamId, terminal: t.info)
    }

    func closeTerminal(_ id: String) throws {
        guard let t = terminals.removeValue(forKey: id) else { throw notFound("terminal", id) }
        terminalOrder.removeAll { $0 == id }
        t.animation?.cancel()
        for s in t.streams { streamOwners[s] = nil; terminalStreams[s] = nil }
        broadcast(.termExited, TerminalExitedEvent(terminalId: id, code: 0))
    }

    /// Writes output to scrollback (shell mode) and every attached stream.
    func emit(_ terminalId: String, _ text: String, recordScrollback: Bool = true) {
        guard var t = terminals[terminalId] else { return }
        let bytes = Data(text.utf8)
        if recordScrollback {
            t.scrollback.append(bytes)
            if t.scrollback.count > MockTerminal.maxScrollback {
                t.scrollback = t.scrollback.suffix(MockTerminal.maxScrollback / 2)
            }
            terminals[terminalId] = t
        }
        for s in t.streams { sendFrame(StreamFrame(kind: .termOutput, streamId: s, payload: bytes)) }
    }

    func terminalInput(streamId: UInt32, bytes: Data) {
        guard let terminalId = terminalStreams[streamId], var t = terminals[terminalId] else { return }
        if t.mode == .top {
            if bytes.contains(UInt8(ascii: "q")) || bytes.contains(0x03) {
                t.mode = .shell
                t.animation?.cancel()
                t.animation = nil
                terminals[terminalId] = t
                emit(terminalId, "\u{1B}[2J\u{1B}[H" + t.shell.prompt)
                try? mutateTerminal(terminalId) { $0.info.title = "zsh" }
            }
            return
        }
        var echo = ""
        var commands: [String] = []
        for byte in bytes {
            switch t.escapeState {
            case 1:
                t.escapeState = byte == UInt8(ascii: "[") || byte == UInt8(ascii: "O") ? 2 : 0
                continue
            case 2:
                if (0x40...0x7E).contains(byte) { t.escapeState = 0 }
                continue
            default:
                break
            }
            switch byte {
            case 0x1B:
                t.escapeState = 1
            case 0x0D, 0x0A:
                echo += "\r\n"
                commands.append(t.line)
                t.line = ""
            case 0x7F, 0x08:
                if !t.line.isEmpty {
                    t.line.removeLast()
                    echo += "\u{8} \u{8}"
                }
            case 0x03:
                echo += "^C\r\n" + t.shell.prompt
                t.line = ""
            case 0x0C:
                echo += "\u{1B}[2J\u{1B}[H" + t.shell.prompt + t.line
            case 0x09:
                break
            default:
                if byte >= 0x20 {
                    let s = String(decoding: [byte], as: UTF8.self)
                    t.line += s
                    echo += s
                }
            }
        }
        terminals[terminalId] = t
        if !echo.isEmpty { emit(terminalId, echo) }
        for command in commands { runCommand(terminalId, command) }
    }

    func runCommand(_ terminalId: String, _ command: String) {
        guard var t = terminals[terminalId] else { return }
        let outcome = t.shell.run(command)
        terminals[terminalId] = t
        switch outcome {
        case .output(let text):
            emit(terminalId, text + t.shell.prompt)
            if command.hasPrefix("cd") { try? mutateTerminal(terminalId) { $0.info.cwd = $0.shell.directory } }
        case .clear:
            emit(terminalId, "\u{1B}[2J\u{1B}[H" + t.shell.prompt)
        case .startTop:
            t.mode = .top
            terminals[terminalId] = t
            emit(terminalId, "\u{1B}[2J", recordScrollback: false)
            try? mutateTerminal(terminalId) { $0.info.title = "top" }
            updateTerminalAnimation(terminalId)
        case .exit:
            emit(terminalId, "logout\r\n\r\n[Process completed]\r\n")
            try? mutateTerminal(terminalId) { $0.info.running = false }
            broadcast(.termExited, TerminalExitedEvent(terminalId: terminalId, code: 0))
        }
    }

    /// Runs the `top` refresh loop while the terminal is in top mode and
    /// someone is attached.
    func updateTerminalAnimation(_ terminalId: String) {
        guard var t = terminals[terminalId] else { return }
        let shouldRun = t.mode == .top && !t.streams.isEmpty
        if shouldRun, t.animation == nil {
            t.animation = Task { await self.topLoop(terminalId) }
        } else if !shouldRun, let task = t.animation {
            task.cancel()
            t.animation = nil
        }
        terminals[terminalId] = t
    }

    func topLoop(_ terminalId: String) async {
        while !Task.isCancelled {
            guard var t = terminals[terminalId], t.mode == .top else { return }
            t.tick += 1
            terminals[terminalId] = t
            emit(terminalId, t.shell.topScreen(tick: t.tick, cols: t.info.cols, rows: t.info.rows), recordScrollback: false)
            do { try await pause(1000) } catch { return }
        }
    }
}
