import CnxTerminal
import CnxTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.cnx", category: "terminal")

/// A terminal tab on the Mac, attached over its own `daemon` channel
/// (cmux-tui protocol, `cmux-tui/spec/commands.md` and `events.md`):
///
/// - `attach-surface {surface}` (bytes mode). The `vt-state` replay and the
///   live `output` chunks are fed to the local Ghostty mirror in order; a
///   `resized` event (protocol 6+) resets the mirror (`ESC c`) and replays.
///   `detached` ends the session.
/// - Input: `send {surface, bytes}` (base64), in order, batched while a
///   request is out, on its own `daemon` channel on the link's input lane
///   (PROTOCOL.md "Lanes"), so a keystroke or ^C never waits behind the
///   output it should interrupt. Until that channel is open (or when it
///   fails) input goes on the attach channel.
/// - Size: `resize-surface {surface, cols, rows}` with the phone's TUI grid,
///   on the attach channel (the daemon gives geometry authority to the
///   attaching client).
///
/// The alternate screen flag is derived from the bytes (no event carries it).
///
/// A channel that ends without `detached` is a dropped link (background,
/// transport switch, Mac restart), not the end of the terminal: the session
/// waits, and ``reconnect()`` (the coordinator calls it on every new link)
/// attaches again, resetting the mirror before the replay and restoring the
/// size.
@MainActor
public final class DaemonTerminalSession: TerminalSession {
    public let surface: Int
    public private(set) var programName: String
    public private(set) var isAlternateScreen = false
    /// The Mac terminal's rows (`vt-state`, `resized`), else the size asked for.
    public var remoteRows: Int? { reportedRows ?? lastSize?.rows ?? 24 }
    private var reportedRows: Int?
    /// The last attach or send failure (shown nowhere yet; logged).
    public private(set) var lastError: String?

    private let open: @Sendable () async throws -> DaemonClient
    private let openInput: (@Sendable () async throws -> DaemonClient)?
    private var client: DaemonClient?
    /// The input-lane channel for `send`, once open.
    private var inputClient: DaemonClient?
    /// Keystrokes not yet sent; sent as one `send` while none is out.
    private var input: [Data] = []
    private var inputDraining = false
    private var handler: (@MainActor (TerminalSessionEvent) -> Void)?
    /// Decodes lines given to `handle(_:)` (the attach stream has its own, off the main actor).
    private lazy var lineParser = DaemonTerminalEventParser(surface: surface)
    private var inbox: DaemonTerminalInbox?
    private var outputPaused = false
    private var eventTask: Task<Void, Never>?
    /// Resizes go out one at a time, in order, on the attach channel.
    private var outbox: [Outgoing] = []

    private enum Outgoing: Sendable {
        case size(columns: Int, rows: Int)
    }
    private var draining = false
    private var pendingSize: (columns: Int, rows: Int)?
    /// The grid last asked for, put back after a reattach.
    private var lastSize: (columns: Int, rows: Int)?
    private var attached = false
    private var attaching = false
    /// The daemon said the surface is gone (`detached`): never reattach.
    private var ended = false
    /// Attached to the surface now.
    public var isAttached: Bool { attached }
    /// Has been attached once (a later attach is a reattach).
    private var everAttached = false
    /// The Mac's name, for the connecting placeholder.
    public var macName: String?

    /// `connecting` until the first attach, `reattaching` after a dropped
    /// link, `attached` while the screen mirrors the Mac's terminal.
    public var connectionState: TerminalConnectionState {
        if attached { return .attached }
        return everAttached ? .reattaching(mac: macName) : .connecting(mac: macName)
    }

    /// `open` returns a client on a fresh `daemon` channel to the Mac;
    /// `openInput`, one on the link's input lane for keystrokes (nil: input
    /// shares the attach channel).
    public init(
        surface: Int,
        programName: String = "zsh",
        open: @escaping @Sendable () async throws -> DaemonClient,
        openInput: (@Sendable () async throws -> DaemonClient)? = nil
    ) {
        self.surface = surface
        self.programName = programName
        self.open = open
        self.openInput = openInput
    }

    public func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
        guard self.handler == nil else { return }
        self.handler = handler
        handler(.connection(connectionState))
        Task { await attach() }
    }

    public func send(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        input.append(bytes)
        drainInput()
    }

    public func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        lastSize = (columns, rows)
        if attached {
            enqueue(.size(columns: columns, rows: rows))
        } else {
            pendingSize = (columns, rows)
        }
    }

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        inbox?.close()
        inbox = nil
        outputPaused = false
        handler = nil
        client = nil
        dropInputLane()
        outbox.removeAll()
        input.removeAll()
    }

    /// Attaches again after a dropped link. A no-op while attached or
    /// attaching, before `start`, and after the surface ended.
    public func reconnect() {
        guard handler != nil, !attached, !attaching, !ended else { return }
        Task { await attach() }
    }

    // MARK: Attach

    private func attach() async {
        guard !attaching else { return }
        attaching = true
        defer { attaching = false }
        do {
            let client = try await open()
            guard handler != nil else { return }
            self.client = client
            await client.start()
            let events = client.events
            eventTask?.cancel()
            inbox?.close()
            // Event lines are decoded off the main actor and reach it in
            // batches, one main-queue hop per batch (DaemonTerminalInbox).
            let inbox = DaemonTerminalInbox { [weak self] batch in
                MainActor.assumeIsolated {
                    guard let self, self.client === client else { return }
                    for event in batch { self.apply(event) }
                }
            }
            inbox.setPaused(outputPaused)
            self.inbox = inbox
            let surface = surface
            eventTask = Task.detached { [weak self] in
                var parser = DaemonTerminalEventParser(surface: surface)
                for await line in events {
                    await inbox.push(parser.parse(line))
                }
                // After the batches already queued (the main queue is FIFO).
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.channelEnded(client) }
                }
            }
            _ = try? await client.request("identify")
            // The replay that follows rebuilds the screen and scrollback. The
            // reset also tells the screen where the Mac's screen starts in its
            // taller mirror (TerminalRowShift).
            setAlternate(false)
            handler?(.output(Data("\u{1B}c".utf8)))
            let reply = try await client.request("attach-surface", params: ["surface": surface])
            if let error = Self.error(in: reply) { throw LinkError(code: "attach", message: error) }
            guard self.client === client else { return }
            attached = true
            everAttached = true
            handler?(.connection(.attached))
            lastError = nil
            pendingSize = nil
            if let size = lastSize {
                outbox.removeAll { if case .size = $0 { true } else { false } }
                outbox.insert(.size(columns: size.columns, rows: size.rows), at: 0)
            }
            drain()
            drainInput()
            openInputLane(for: client)
        } catch {
            lastError = LinkController.reason(error)
            log.error("attach surface \(self.surface): \(String(describing: error), privacy: .public)")
            emitText("\r\n\u{1B}[2m[\(lastError ?? "Can't attach to this terminal")]\u{1B}[0m\r\n")
        }
    }

    /// The channel ended. After `detached` that is the end; otherwise the link
    /// dropped and the session waits for ``reconnect()``.
    private func channelEnded(_ client: DaemonClient) {
        guard self.client === client else { return }
        self.client = nil
        dropInputLane()
        attached = false
        draining = false
        guard handler != nil, !ended else { return }
        handler?(.connection(connectionState))
        log.info("surface \(self.surface): link dropped, waiting to reattach")
    }

    /// One event line from the daemon channel, decoded on the main actor
    /// (tests; the attach stream decodes off the main actor).
    func handle(_ line: Data) {
        for event in lineParser.parse(line) { apply(event) }
    }

    private func apply(_ event: DaemonTerminalInbound) {
        switch event {
        case .output(let data):
            handler?(.output(data))
        case .alternateScreen(let on):
            setAlternate(on)
        case .rows(let rows):
            reportedRows = rows
        case .resetMirror:
            setAlternate(false)
            handler?(.output(Data("\u{1B}c".utf8)))
        case .detached(let reason):
            ended(reason: reason)
        }
    }

    /// The screen is behind: stop reading output from the Mac until it
    /// catches up (the link's own flow control then holds the Mac back).
    public func setOutputPaused(_ paused: Bool) {
        outputPaused = paused
        inbox?.setPaused(paused)
    }

    private func emitText(_ text: String) {
        handler?(.output(Data(text.utf8)))
    }

    private func setAlternate(_ on: Bool) {
        guard isAlternateScreen != on else { return }
        isAlternateScreen = on
        handler?(.alternateScreen(on))
    }

    private func ended(reason: String?) {
        guard handler != nil, !ended else { return }
        ended = true
        emitText("\r\n\u{1B}[2m[Detached\(reason.map { ": \($0)" } ?? "")]\u{1B}[0m\r\n")
        handler?(.exited(code: 0))
        attached = false
    }

    // MARK: Outbox

    private func enqueue(_ item: Outgoing) {
        outbox.append(item)
        drain()
    }

    private func drain() {
        guard attached, !draining, let client, !outbox.isEmpty else { return }
        draining = true
        let next = outbox.removeFirst()
        let surface = surface
        Task { [weak self] in
            guard let self else { return }
            do {
                let cmd: String
                let reply: Data
                switch next {
                case .size(let columns, let rows):
                    cmd = "resize-surface"
                    reply = try await client.request(cmd, params: ["surface": surface, "cols": columns, "rows": rows])
                }
                if let error = Self.error(in: reply) {
                    lastError = error
                    log.error("\(cmd, privacy: .public) failed: \(error, privacy: .public)")
                }
            } catch {
                // The channel failed under the request (a dead link): keep the
                // keystrokes for the reattach instead of dropping them.
                lastError = LinkController.reason(error)
                if self.client === client {
                    self.client = nil
                    attached = false
                    handler?(.connection(connectionState))
                }
                outbox.insert(next, at: 0)
                draining = false
                return
            }
            draining = false
            drain()
        }
    }

    // MARK: Input lane

    /// Opens the input-lane channel for the attach `main` (a no-op without
    /// `openInput`). It is dropped with the attach channel.
    private func openInputLane(for main: DaemonClient) {
        guard let openInput else { return }
        Task { [weak self] in
            guard let lane = try? await openInput() else { return }
            await lane.start()
            guard let self, self.client === main, self.attached, self.inputClient == nil else {
                await lane.close()
                return
            }
            self.inputClient = lane
            let events = lane.events
            Task { [weak self] in
                for await _ in events {}
                guard let self, self.inputClient === lane else { return }
                self.inputClient = nil
            }
        }
    }

    /// Closes the input-lane channel (the Mac drops its daemon connection).
    private func dropInputLane() {
        guard let lane = inputClient else { return }
        inputClient = nil
        Task { await lane.close() }
    }

    /// Sends queued keystrokes as one `send`, one request at a time, on the
    /// input lane when open, else on the attach channel.
    private func drainInput() {
        guard attached, !inputDraining, !input.isEmpty, let target = inputClient ?? client else { return }
        inputDraining = true
        let batch = input.reduce(into: Data()) { $0.append($1) }
        input.removeAll()
        let surface = surface
        Task { [weak self] in
            guard let self else { return }
            do {
                let encoded = batch.base64EncodedString()
                let request: @Sendable () async throws -> Data = { try await target.request("send", params: ["surface": surface, "bytes": encoded]) }
                // A lane request gets an answer within seconds or the lane is
                // given up. The batch is not sent again then: the Mac may
                // already have typed it, and a doubled Return runs a command
                // twice.
                let reply: Data
                if target !== client {
                    guard let answer = try await Self.within(.seconds(10), request) else {
                        log.error("send on the input lane got no answer; using the attach channel")
                        if inputClient === target { dropInputLane() }
                        inputDraining = false
                        drainInput()
                        return
                    }
                    reply = answer
                } else {
                    reply = try await request()
                }
                if let error = Self.error(in: reply) {
                    lastError = error
                    log.error("send failed: \(error, privacy: .public)")
                }
            } catch {
                // Keep the keystrokes: retry on the attach channel when the
                // lane failed, or after the reattach when the link dropped.
                lastError = LinkController.reason(error)
                input.insert(batch, at: 0)
                if inputClient === target {
                    dropInputLane()
                } else if self.client === target {
                    self.client = nil
                    inputClient = nil
                    attached = false
                    handler?(.connection(connectionState))
                }
            }
            inputDraining = false
            drainInput()
        }
    }

    /// `operation`'s result, or nil when it takes longer than `limit`. Does
    /// not wait for `operation` to notice cancellation (a request on a dead
    /// channel never does).
    private static func within(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> Data) async throws -> Data? {
        let once = RaceOnce()
        let result: Result<Data?, any Error> = await withCheckedContinuation { continuation in
            let work = Task {
                let result: Result<Data?, any Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                if once.claim() { continuation.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(for: limit)
                if once.claim() {
                    work.cancel()
                    continuation.resume(returning: .success(nil))
                }
            }
        }
        return try result.get()
    }

    private static func error(in reply: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return "bad reply" }
        if object["ok"] as? Bool == false { return (object["error"] as? String) ?? "refused" }
        if let error = object["error"] as? String { return error }
        return nil
    }
}
