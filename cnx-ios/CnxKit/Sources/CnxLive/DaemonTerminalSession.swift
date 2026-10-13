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
/// - Input: `send {surface, bytes}` (base64), in order.
/// - Size: `resize-surface {surface, cols, rows}` with the phone's TUI grid.
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
    /// The last attach or send failure (shown nowhere yet; logged).
    public private(set) var lastError: String?

    private let open: @Sendable () async throws -> DaemonClient
    private var client: DaemonClient?
    private var handler: (@MainActor (TerminalSessionEvent) -> Void)?
    private var detector = AlternateScreenDetector()
    private var eventTask: Task<Void, Never>?
    /// Input and resizes go out one at a time, in order.
    private var outbox: [Outgoing] = []

    private enum Outgoing: Sendable {
        case bytes(String)
        case size(columns: Int, rows: Int)
    }
    private var draining = false
    private var pendingSize: (columns: Int, rows: Int)?
    /// The grid last asked for, put back after a reattach.
    private var lastSize: (columns: Int, rows: Int)?
    private var attached = false
    private var attaching = false
    /// The mirror has content from an earlier attach: reset it before a replay.
    private var hasAttachedBefore = false
    /// The daemon said the surface is gone (`detached`): never reattach.
    private var ended = false
    /// Attached to the surface now.
    public var isAttached: Bool { attached }

    /// `open` returns a client on a fresh `daemon` channel to the Mac.
    public init(surface: Int, programName: String = "zsh", open: @escaping @Sendable () async throws -> DaemonClient) {
        self.surface = surface
        self.programName = programName
        self.open = open
    }

    public func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
        guard self.handler == nil else { return }
        self.handler = handler
        Task { await attach() }
    }

    public func send(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        enqueue(.bytes(bytes.base64EncodedString()))
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
        handler = nil
        client = nil
        outbox.removeAll()
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
            eventTask = Task { [weak self] in
                for await line in events {
                    guard let self else { return }
                    self.handle(line)
                }
                self?.channelEnded(client)
            }
            _ = try? await client.request("identify")
            if hasAttachedBefore {
                // The replay that follows rebuilds the screen and scrollback.
                detector = AlternateScreenDetector()
                setAlternate(false)
                handler?(.output(Data("\u{1B}c".utf8)))
            }
            let reply = try await client.request("attach-surface", params: ["surface": surface])
            if let error = Self.error(in: reply) { throw LinkError(code: "attach", message: error) }
            guard self.client === client else { return }
            attached = true
            hasAttachedBefore = true
            lastError = nil
            pendingSize = nil
            if let size = lastSize {
                outbox.removeAll { if case .size = $0 { true } else { false } }
                outbox.insert(.size(columns: size.columns, rows: size.rows), at: 0)
            }
            drain()
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
        attached = false
        draining = false
        guard handler != nil, !ended else { return }
        log.info("surface \(self.surface): link dropped, waiting to reattach")
    }

    /// One event line from the daemon channel (attach stream events for this surface).
    func handle(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = object["event"] as? String else { return }
        if let id = object["surface"] as? Int, id != surface { return }
        switch event {
        case "vt-state":
            emit(base64: object["data"] as? String)
            emit(base64: object["pending"] as? String)
        case "output":
            emit(base64: object["data"] as? String)
        case "resized":
            // The authoritative mirror changed size: start over from the replay.
            detector = AlternateScreenDetector()
            setAlternate(false)
            handler?(.output(Data("\u{1B}c".utf8)))
            emit(base64: (object["replay"] as? String) ?? (object["data"] as? String))
            emit(base64: object["pending"] as? String)
        case "detached":
            ended(reason: object["reason"] as? String)
        default:
            break
        }
    }

    private func emit(base64: String?) {
        guard let base64, let data = Data(base64Encoded: base64), !data.isEmpty else { return }
        if let alternate = detector.scan(data) {
            handler?(.output(data))
            setAlternate(alternate)
        } else {
            handler?(.output(data))
        }
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
                case .bytes(let base64):
                    cmd = "send"
                    reply = try await client.request(cmd, params: ["surface": surface, "bytes": base64])
                case .size(let columns, let rows):
                    cmd = "resize-surface"
                    reply = try await client.request(cmd, params: ["surface": surface, "cols": columns, "rows": rows])
                }
                if let error = Self.error(in: reply) {
                    lastError = error
                    log.error("\(cmd, privacy: .public) failed: \(error, privacy: .public)")
                }
            } catch {
                lastError = LinkController.reason(error)
            }
            draining = false
            drain()
        }
    }

    private static func error(in reply: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return "bad reply" }
        if object["ok"] as? Bool == false { return (object["error"] as? String) ?? "refused" }
        if let error = object["error"] as? String { return error }
        return nil
    }
}
