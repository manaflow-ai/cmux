public import CmuxMobileSSH
import Foundation

/// A single-pane tmux window as a terminal byte channel. tmux owns its
/// grid, lifecycle and selected pane. This client never selects a window,
/// creates a session, runs shell input, or replays unacknowledged keys.
actor SSHTmuxControlChannel: SSHShellChannel {
    nonisolated let events: AsyncStream<SSHSessionEvent>
    private let sink: AsyncStream<SSHSessionEvent>.Continuation
    private let base: any SSHShellChannel
    private let window: SSHTmuxWindow
    private let changed: @Sendable () async -> Void
    private let clock: any Clock<Duration>
    private var decoder = SSHTmuxControlDecoder()
    private var pending: [Request] = [.attach]
    private var reader: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, any Error>?
    private var closed = false
    private var ready = false
    private var refreshing = false
    private var refreshAgain = false
    private var cols: Int
    private var rows: Int
    private var requestedGrid: (cols: Int, rows: Int)
    private var pane: String?
    private var capture: [Data] = []

    private enum Request { case attach, identity, mute, size, inspect, capture, metadata, enable, input }

    init(base: any SSHShellChannel, window: SSHTmuxWindow, cols: Int, rows: Int,
         clock: any Clock<Duration> = ContinuousClock(), changed: @escaping @Sendable () async -> Void) {
        self.base = base
        self.window = window
        self.cols = cols
        self.rows = rows
        requestedGrid = (cols, rows)
        self.clock = clock
        self.changed = changed
        (events, sink) = AsyncStream.makeStream(of: SSHSessionEvent.self, bufferingPolicy: .bufferingOldest(128))
    }

    /// Doesn't report a live terminal until the owner snapshot is queued and
    /// its live output is enabled. Cancellation and a silent peer both close
    /// the SSH chain and resolve this one bounded readiness waiter.
    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !closed, reader == nil, !Task.isCancelled else {
                    continuation.resume(throwing: SSHSessionFailure.shellRejected)
                    return
                }
                waiter = continuation
                armDeadline()
                reader = Task { await self.receive() }
            }
        } onCancel: {
            // task-owner: cancellation cleanup owns this task until the SSH chain closes
            Task { await self.close() }
        }
    }

    func write(_ data: Data) async throws {
        guard ready, !closed, let pane else { throw SSHSessionFailure.network }
        guard data.count <= 16 * 1024 else { throw SSHSessionFailure.shellRejected }
        guard !data.isEmpty else { return }
        let bytes = Array(data)
        let count = (bytes.count + 511) / 512
        guard pending.count + count <= 64 else { throw SSHSessionFailure.network }
        var commands: [(Request, String)] = []
        for offset in stride(from: 0, to: bytes.count, by: 512) {
            let hex = bytes[offset..<min(bytes.count, offset + 512)].map { String(format: "%02x", $0) }.joined(separator: " ")
            commands.append((.input, "send-keys -H -t '\(pane)' \(hex)"))
        }
        try await send(commands)
    }

    func resize(cols: Int, rows: Int) async throws {
        guard Self.validGrid(cols, rows), !closed else { throw SSHSessionFailure.shellRejected }
        guard requestedGrid != (cols, rows) else { return }
        requestedGrid = (cols, rows)
        try await refresh()
    }

    func close() async { await finish(.network) }

    private func receive() async {
        do {
            guard Self.validGrid(cols, rows) else { throw SSHSessionFailure.shellRejected }
            for await event in base.events {
                guard !closed, !Task.isCancelled else { break }
                switch event {
                case .stdout(let data):
                    for frame in try decoder.append(data) {
                        switch frame {
                        case .response(let lines, let failed): try await response(lines, failed: failed)
                        case .notification(let line): try await notification(line)
                        }
                    }
                case .stderr: break // Diagnostics never become terminal or protocol bytes.
                case .exitStatus, .exitSignal: throw SSHSessionFailure.sessionGone
                case .closed: throw SSHSessionFailure.network
                }
            }
            if !closed { await finish(.network) }
        } catch {
            await finish(SSHSessionFailure(error))
        }
    }

    private func response(_ lines: [Data], failed: Bool) async throws {
        guard !pending.isEmpty, !failed else { throw SSHSessionFailure.shellRejected }
        let request = pending.removeFirst()
        switch request {
        case .attach:
            try await send([(.identity, "display-message -p '#{pid} #{start_time}'")])
        case .identity:
            guard lines == [Data("\(window.serverPID) \(window.serverStart)".utf8)] else {
                throw SSHSessionFailure.sessionGone
            }
            try await refresh()
        case .mute, .size, .input: break
        case .inspect: try await inspect(lines)
        case .capture: capture = lines
        case .metadata:
            guard let pane else { throw SSHSessionFailure.sessionGone }
            try emit(SSHTmuxSnapshot.replay(lines: capture, metadata: lines, pane: pane, cols: cols, rows: rows,
                                            historyRows: SSHTmuxSnapshot.maximumHistoryRows))
            capture = []
        case .enable:
            refreshing = false
            if refreshAgain {
                refreshAgain = false
                try await refresh()
            } else {
                ready = true
                waiter?.resume()
                waiter = nil
            }
        }
        armDeadline()
    }

    private func refresh() async throws {
        guard !closed else { throw SSHSessionFailure.network }
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        ready = false
        (cols, rows) = requestedGrid
        // Explicit window sizing leaves other clients' selection alone. tmux
        // still decides the canonical size according to its window-size policy.
        try await send([
            (.mute, "refresh-client -f no-output"),
            (.size, "refresh-client -f '!ignore-size' -C '\(window.windowID):\(cols)x\(rows)'"),
            (.inspect, "list-panes -s -t '\(window.sessionID)' -F '#{window_id} #{pane_id} #{pane_width} #{pane_height}'"),
        ])
    }

    private func inspect(_ lines: [Data]) async throws {
        guard lines.count <= 256 else { throw SSHSessionFailure.shellRejected }
        var selected: [String] = []
        var panes: [String] = []
        for line in lines {
            let fields = String(decoding: line, as: UTF8.self).split(separator: " ").map(String.init)
            guard fields.count == 4, SSHTmuxWindow.validID(fields[0], prefix: "@"),
                  SSHTmuxWindow.validID(fields[1], prefix: "%"),
                  let width = Int(fields[2]), let height = Int(fields[3]), Self.validGrid(width, height) else {
                throw SSHSessionFailure.shellRejected
            }
            panes.append(fields[1])
            let isTarget = if let paneID = window.paneID {
                fields[0] == window.windowID && fields[1] == paneID
            } else {
                fields[0] == window.windowID
            }
            if isTarget {
                guard width == cols, height == rows else { throw SSHSessionFailure.shellRejected }
                selected.append(fields[1])
            }
        }
        // Modern discovery may identify the host's active pane in a split
        // window. If that identity is absent or duplicated, refuse rather
        // than attaching whichever pane happens to be listed first. Legacy
        // targets retain the original single-pane-only guard.
        guard selected.count == 1, Set(panes).count == panes.count else { throw SSHSessionFailure.shellRejected }
        let selectedPane = selected[0]
        pane = selectedPane
        let outputs = panes.map { "-A '\($0):\($0 == selectedPane ? "on" : "off")'" }.joined(separator: " ")
        // A single command sequence takes capture + cursor/modes + output
        // enable in the owner's command queue, so no PTY bytes fall in a gap.
        try await send([
            // Capture a bounded normal-screen scrollback prefix as well as
            // the visible rows. The replay splits the final `rows` lines back
            // out; a partial or ambiguous capture fails closed.
            (.capture, "capture-pane -p -e -C -S -\(SSHTmuxSnapshot.maximumHistoryRows) -E - -t '\(selectedPane)'"),
            (.metadata, "display-message -p -t '\(selectedPane)' '\(SSHTmuxSnapshot.format)'"),
            (.enable, "refresh-client -f '!no-output' \(outputs)"),
        ], separator: " ; ")
    }

    private func notification(_ bytes: Data) async throws {
        if bytes.starts(with: Data("%output ".utf8)) {
            let rest = bytes.dropFirst(8)
            guard let separator = rest.firstIndex(of: 32) else { throw SSHSessionFailure.shellRejected }
            let id = String(decoding: rest[..<separator], as: UTF8.self)
            guard SSHTmuxWindow.validID(id, prefix: "%") else { throw SSHSessionFailure.shellRejected }
            if ready, id == pane { try emit(SSHTmuxControlDecoder.unescape(Data(rest[rest.index(after: separator)...]))) }
            return
        }
        let fields = String(decoding: bytes, as: UTF8.self).split(separator: " ").map(String.init)
        guard let name = fields.first else { throw SSHSessionFailure.shellRejected }
        if name == "%exit" { throw SSHSessionFailure.sessionGone }
        if name == "%window-close", fields.dropFirst().first == window.windowID {
            await changed()
            throw SSHSessionFailure.sessionGone
        }
        if ["%layout-change", "%window-pane-changed", "%window-add", "%window-close", "%session-changed"].contains(name) {
            await changed()
            if !pending.contains(where: { switch $0 { case .attach, .identity: return true; default: return false } }) { try await refresh() }
        } else if ["%window-renamed", "%session-renamed", "%sessions-changed"].contains(name) {
            await changed()
        }
    }

    private func send(_ commands: [(Request, String)], separator: String = "\n") async throws {
        guard !closed, pending.count + commands.count <= 64 else { throw SSHSessionFailure.network }
        let wasEmpty = pending.isEmpty
        pending.append(contentsOf: commands.map(\.0))
        if wasEmpty { armDeadline() }
        try await base.write(Data((commands.map(\.1).joined(separator: separator) + "\n").utf8))
    }

    private func emit(_ data: Data) throws {
        for offset in stride(from: 0, to: data.count, by: 16 * 1024) {
            let bytes = data.subdata(in: offset..<min(offset + 16 * 1024, data.count))
            guard case .enqueued = sink.yield(.stdout(bytes)) else { throw SSHSessionFailure.network }
        }
    }

    private func armDeadline() {
        deadline?.cancel()
        deadline = nil
        guard !closed, !pending.isEmpty else { return }
        let clock = self.clock
        deadline = Task { [weak self] in
            do {
                // wakeup-allow: one-shot deadline for outstanding SSH control replies; cancelled on reply or close
                try await clock.sleep(for: .seconds(10))
                await self?.finish(.network)
            } catch {}
        }
    }

    private func finish(_ failure: SSHSessionFailure) async {
        guard !closed else { return }
        closed = true
        ready = false
        reader?.cancel()
        reader = nil
        deadline?.cancel()
        deadline = nil
        waiter?.resume(throwing: failure)
        waiter = nil
        pending = []
        capture = []
        // Semantic refusal must not endlessly reconnect to an unsupported
        // layout. A dropped connection reattaches and obtains a fresh snapshot.
        if !failure.isRetryable { sink.yield(.exitStatus(1)) }
        sink.yield(.closed)
        sink.finish()
        await base.close()
    }

    private static func validGrid(_ cols: Int, _ rows: Int) -> Bool {
        (1...512).contains(cols) && (1...256).contains(rows)
    }
}
