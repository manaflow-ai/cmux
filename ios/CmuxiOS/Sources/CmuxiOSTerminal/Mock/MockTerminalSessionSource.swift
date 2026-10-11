#if DEBUG
import CmuxTerminalStream
import CryptoKit
import Foundation

/// A terminal owner for demos and the simulator gallery until the transport
/// engine lands. It acts as a session host under `terminal-snapshot-v1`: its
/// terminal is a real ghostty-next surface (`GhosttyFixtureHost`) that parses
/// everything it sends, so every snapshot and digest is Ghostty's own
/// encoding. A tiny line-discipline shell echoes typed keys.
///
/// On attach it sends the grid (a new generation), `snapshot_ready`, live
/// bytes and a digest; after `gridChangeDelay` on the injected clock it
/// changes the grid (next generation), redraws as a host does after a
/// reflow, and sends a new `snapshot_ready` and digest. The grid area has its
/// own background, so a screenshot shows the host's grid inside the view.
public actor MockTerminalSessionSource: TerminalSessionSource {
    public static let demo = TerminalRef(host: "host_mock", terminal: "term_mock", title: "zsh", hostName: "Mac mini")

    private let clock: any Clock<Duration>
    private let gridChangeDelay: Duration
    private var host: GhosttyFixtureHost?
    private var continuation: AsyncStream<TerminalChannelEvent>.Continuation?
    private var gridChange: Task<Void, Never>?
    private var generation: UInt32 = 0
    private var grid = (cols: 44, rows: 22)
    /// Host PTY offset: every byte the host terminal parsed.
    private var offset: UInt64 = 0
    private var line = ""
    private let snapshotVersion = GhosttyOutputSurface.snapshotVersion

    private static let background = "\u{1B}[48;2;40;44;58m"
    private static let reset = "\u{1B}[0m" + background
    private static let prompt = "\u{1B}[1mlawrence@mini" + reset + " \u{1B}[2m~/cmux" + reset + " % "

    public init(gridChangeDelay: Duration = .seconds(4), clock: any Clock<Duration> = ContinuousClock()) {
        self.gridChangeDelay = gridChangeDelay
        self.clock = clock
    }

    public func terminals() -> [TerminalRef] { [Self.demo] }

    public func attach(_ terminal: TerminalRef) async -> AsyncStream<TerminalChannelEvent> {
        // A full buffer drops the newest frame; the viewer sees the offset gap and resyncs.
        let (stream, continuation) = AsyncStream.makeStream(of: TerminalChannelEvent.self,
                                                            bufferingPolicy: .bufferingOldest(1024))
        self.continuation?.finish()
        self.continuation = continuation
        continuation.yield(.path(.lan, rttMilliseconds: 3))
        if host == nil {
            guard let made = await MainActor.run(body: { try? GhosttyFixtureHost() }) else {
                continuation.yield(.closed(reason: "mock host unavailable"))
                continuation.finish()
                return stream
            }
            host = made
            await setGrid(cols: 44, rows: 22)
            await write(Self.screen(title: "restored from a GHOSTSNP snapshot", grid: grid, generation: generation), send: false)
        } else {
            continuation.yield(.grid(cols: grid.cols, rows: grid.rows, generation: generation))
        }
        await sendReady()
        await write("echo live\r\nlive bytes after the snapshot\r\n" + Self.prompt, send: true)
        await sendDigest()
        gridChange?.cancel()
        let clock = self.clock
        let delay = self.gridChangeDelay
        gridChange = Task { [weak self] in
            // wakeup-allow: DEBUG mock script, one-shot delay on the injected clock, cancelled on detach
            do { try await clock.sleep(for: delay) } catch { return }
            await self?.changeGrid()
        }
        return stream
    }

    public func setPresence(_ terminal: TerminalRef, visible: Bool, cols: Int, rows: Int) {}

    public func send(_ input: Data, to terminal: TerminalRef) async {
        var out = ""
        for scalar in String(decoding: input, as: UTF8.self).unicodeScalars {
            switch scalar {
            case "\r", "\n":
                out += "\r\n" + respond(to: line) + Self.prompt
                line = ""
            case "\u{7F}", "\u{08}":
                if !line.isEmpty { line.removeLast(); out += "\u{08} \u{08}" }
            default:
                line.unicodeScalars.append(scalar)
                out.unicodeScalars.append(scalar)
            }
        }
        if !out.isEmpty { await write(out, send: true) }
    }

    public func requestSnapshot(_ request: SnapshotRequest, for terminal: TerminalRef) async {
        await sendReady()
    }

    public func detach(_ terminal: TerminalRef) async {
        gridChange?.cancel()
        gridChange = nil
        continuation?.finish()
        continuation = nil
        await host?.close()
        host = nil
    }

    // MARK: Host side

    /// The host reflows to a smaller grid: new generation, redraw, snapshot.
    private func changeGrid() async {
        await setGrid(cols: 32, rows: 14)
        await write(Self.screen(title: "host reflowed to a new grid", grid: grid, generation: generation), send: false)
        await sendReady()
        await sendDigest()
    }

    private func setGrid(cols: Int, rows: Int) async {
        generation += 1
        grid = (cols, rows)
        _ = await host?.setGrid(cols: cols, rows: rows, generation: UInt64(generation))
        continuation?.yield(.grid(cols: cols, rows: rows, generation: generation))
    }

    /// The host parses `text`; `send` also streams it as a `bytes` frame.
    private func write(_ text: String, send: Bool) async {
        let data = Data(text.utf8)
        await host?.feed(data)
        offset += UInt64(data.count)
        guard send else { return }
        yield(TerminalFrame(kind: .bytes, generation: generation, offset: offset, payload: data))
    }

    private func sendReady() async {
        guard let ready = await host?.encode(.ready) else { return }
        yield(TerminalFrame(kind: .snapshotReady, generation: generation, offset: offset,
                            snapshotVersion: snapshotVersion, payload: ready))
    }

    private func sendDigest() async {
        guard let ready = await host?.encode(.ready) else { return }
        yield(TerminalFrame(kind: .digest, generation: generation, offset: offset,
                            snapshotVersion: snapshotVersion, payload: Data(SHA256.hash(data: ready))))
    }

    private func yield(_ frame: TerminalFrame) {
        continuation?.yield(.frame(frame.encoded))
    }

    private static func screen(title: String, grid: (cols: Int, rows: Int), generation: UInt32) -> String {
        // Erase with the grid background (BCE) so the grid's extent is visible.
        background + "\u{1B}[2J\u{1B}[H" +
        "\u{1B}[1;36mgrid \(grid.cols)x\(grid.rows), generation \(generation)" + reset + "\r\n" +
        "\u{1B}[7m" + title + reset + "\r\n" +
        "Last login: Thu Oct  2 07:58 on ttys004\r\n" +
        prompt + "git status --short\r\n" +
        " \u{1B}[31mM" + reset + " ios/CmuxiOS/Package.swift\r\n" +
        "\u{1B}[32m??" + reset + " CmuxiOSTerminal/Stream/\r\n" +
        prompt
    }

    private func respond(to command: String) -> String {
        switch command.trimmingCharacters(in: .whitespaces) {
        case "": ""
        case "ls": "Package.swift  Sources  Tests\r\n"
        case "date": "\(Date())\r\n"
        default: "zsh: command not found: \(command)\r\n"
        }
    }
}
#endif
