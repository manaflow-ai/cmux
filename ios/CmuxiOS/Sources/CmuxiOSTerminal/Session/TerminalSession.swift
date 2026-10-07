public import CmuxTerminalRenderCore
import CmuxTerminalStream
import Foundation

/// Binds one `TerminalByteSource` to one `GhosttyTerminalView`. Screens of
/// any lane (the terminal screen, an SSH session, the benchmark) own one
/// session per visible terminal and call `start` when it appears and `stop`
/// when it leaves.
///
/// `.host` sources run under `terminal-snapshot-v1` through
/// `TerminalStreamPipeline` (snapshot first, stale generations dropped, gaps
/// and digest mismatches resync, READY deadline, throttle retry). `.local`
/// sources feed raw bytes. Either way every write to the surface runs on the
/// view's serial output queue in arrival order; the main actor only enqueues.
@MainActor
public final class TerminalSession {
    public let source: any TerminalByteSource
    public let view: GhosttyTerminalView
    /// The status changed (path, title, notice).
    public var onStatus: ((TerminalSessionStatus) -> Void)?
    /// Bytes parsed by the surface (benchmark accounting), after each chunk.
    public var onParsed: ((Int) -> Void)?
    public private(set) var status = TerminalSessionStatus() {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    private(set) var stats = TerminalStreamStats()

    /// Deadlines (READY, throttle retry) sleep on this clock (injected).
    private let clock: any Clock<Duration>
    private var events: Task<Void, Never>?
    private var chromeTasks: [Task<Void, Never>] = []
    private var retry: Task<Void, Never>?
    private var readyDeadline: Task<Void, Never>?
    private var pipeline: TerminalStreamPipeline?
    /// The last close; the next open waits for it, so a reattach never races
    /// its own detach.
    private var closing: Task<Void, Never>?
    /// Input writes in call order, drained by one task into `source.send`.
    private nonisolated let inputContinuation: AsyncStream<Data>.Continuation
    private let inputPump: Task<Void, Never>

    public init(source: any TerminalByteSource, view: GhosttyTerminalView,
                clock: any Clock<Duration> = ContinuousClock()) {
        precondition(source.authority == view.authority, "the view's I/O mode must match the source's authority")
        self.source = source
        self.view = view
        self.clock = clock
        let source = self.source
        // One ordered pipe: a Task per write would let keystrokes overtake
        // each other (c1-terminal-rpc.md section 5).
        let (inputs, inputContinuation) = AsyncStream<Data>.makeStream()
        self.inputContinuation = inputContinuation
        inputPump = Task {
            for await data in inputs { try? await source.send(data) }
        }
        view.onInput = { data in inputContinuation.yield(data) }
        view.onViewportChange = { viewport in
            Task { await source.viewportChanged(viewport) }
        }
        view.onTitle = { [weak self] title in self?.status.title = title }
    }

    deinit {
        inputContinuation.finish()
    }

    public var isRunning: Bool { events != nil }

    /// DEBUG diagnostics of the surface and the stream.
    public var diagnostics: [String: String] {
        view.diagnostics.merging(stats.diagnostics) { _, stream in stream }
    }

    /// Opens the source (a new connection) and starts applying its events.
    public func start() {
        guard events == nil else { return }
        let pipeline = self.pipeline ?? makePipeline()
        self.pipeline = pipeline
        if source.authority == .host {
            // Each open is a new connection: request ids of an older one are
            // void, and the first READY must arrive before the deadline.
            pipeline.attachStarted()
        }
        let source = self.source
        let grid = view.fittingGrid
        let viewport = view.viewport ?? TerminalViewport(cols: grid.cols, rows: grid.rows, visible: view.isPresented)
        followChrome()
        let closing = self.closing
        events = Task { [weak self] in
            await closing?.value
            guard let stream = try? await source.open(viewport) else { return }
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    /// Closes the connection. The terminal keeps its state for a later `start`.
    public func stop() {
        events?.cancel()
        events = nil
        for task in chromeTasks { task.cancel() }
        chromeTasks.removeAll()
        retry?.cancel()
        retry = nil
        readyDeadline?.cancel()
        readyDeadline = nil
        pipeline?.connectionReset()
        let source = self.source
        let previous = closing
        closing = Task {
            await previous?.value
            await source.close()
        }
    }

    /// Asks the source for the page of scrollback before the oldest it
    /// holds (sources that load history on demand; others ignore it).
    public func loadOlderHistory() {
        guard let loader = source as? any TerminalHistoryLoading else { return }
        Task { await loader.loadOlderHistory() }
    }

    /// Whether the source can load older scrollback at all.
    public var loadsHistory: Bool { source is any TerminalHistoryLoading }

    /// Connection and history states of sources that report them.
    private func followChrome() {
        if let reporter = source as? any TerminalConnectionReporting {
            chromeTasks.append(Task { [weak self] in
                for await state in await reporter.connectionStates() {
                    self?.status.connection = state
                }
            })
        }
        if let loader = source as? any TerminalHistoryLoading {
            chromeTasks.append(Task { [weak self] in
                for await state in await loader.historyStates() {
                    self?.status.history = state
                }
            })
        }
    }

    private func makePipeline() -> TerminalStreamPipeline {
        TerminalStreamPipeline(renderer: view, terminal: source.terminalID) { [weak self] controls, stats in
            guard let self else { return }
            let fed = stats.fedBytes - self.stats.fedBytes
            self.stats = stats
            if fed > 0 { self.onParsed?(fed) }
            for control in controls { self.handle(control) }
        }
    }

    private func apply(_ event: TerminalSourceEvent) {
        switch event {
        case .frame(let frame):
            if !status.hasContent { status.hasContent = true }
            pipeline?.receive(frame: frame)
        case .bytes(let bytes):
            if !status.hasContent { status.hasContent = true }
            pipeline?.feed(bytes)
        case .grid(let cols, let rows, let generation):
            pipeline?.grid(cols: cols, rows: rows, generation: generation)
        case .snapshotThrottled(let milliseconds, let requestID):
            pipeline?.throttled(retryAfterMilliseconds: milliseconds, requestID: requestID)
        case .title(let title):
            status.title = title
        case .path(let path, let rtt):
            status.path = path
            status.rttMilliseconds = rtt
        case .kicked(let name):
            status.notice = .kicked(byDisplayName: name)
        case .closed(let reason):
            status.notice = .closed(reason: reason)
        }
    }

    private func handle(_ control: TerminalStreamControl) {
        switch control {
        case .send(let request):
            let source = self.source
            Task { try? await source.requestSnapshot(request) }
        case .retryAfter(let milliseconds):
            retry?.cancel()
            let clock = self.clock
            retry = Task { [weak self] in
                // wakeup-allow: one-shot deadline the host asked for (snapshot_throttled), injected clock, cancelled with the session
                do { try await clock.sleep(for: .milliseconds(milliseconds)) } catch { return }
                self?.pipeline?.retryDue()
            }
        case .versionMismatch:
            status.notice = .byteReplay
        case .armReadyDeadline(let epoch, let milliseconds):
            readyDeadline?.cancel()
            let clock = self.clock
            readyDeadline = Task { [weak self] in
                // wakeup-allow: one-shot READY deadline (terminal-snapshot-v1 resync), injected clock, cancelled with the session
                do { try await clock.sleep(for: .milliseconds(milliseconds)) } catch { return }
                self?.pipeline?.readyDeadline(epoch)
            }
        case .reattach:
            // The host never answered: a new connection gets a fresh READY.
            guard events != nil else { return }
            stop()
            start()
        }
    }
}
