import CmuxiOSFeatureKit
public import CmuxTerminalRenderCore
public import CmuxTerminalStream
public import Foundation

/// A `.local` terminal source over an SSH login shell (a2-ghostty.md 2.1).
///
/// The phone's Ghostty surface is the only parser: channel output goes to
/// it as `.bytes` in order, its query replies come back through `send`, and
/// `viewportChanged` is the SSH `window-change`. When the connection drops
/// (not a user close, an exit, or a refusal), the source reconnects after
/// `SSHReconnectPolicy` backoff on the injected clock and the stream goes on:
/// the renderer keeps its grid and the new shell starts below the old output.
/// Nothing polls; idle sessions rely on kernel TCP keepalive.
public actor SSHTerminalByteSource: TerminalByteSource {
    public nonisolated let authority: TerminalAuthority = .local
    public nonisolated let terminalID: String

    private let connector: any SSHShellConnector
    private let policy: SSHReconnectPolicy
    private let clock: any Clock<Duration>
    private let title: String?

    private var viewport = TerminalViewport(cols: 80, rows: 24, visible: true)
    /// The grid the server last heard (PTY request or window-change).
    private var serverGrid: (cols: Int, rows: Int)?
    private var channel: (any SSHShellChannel)?
    private var continuation: AsyncStream<TerminalSourceEvent>.Continuation?
    private var run: Task<Void, Never>?
    private var backoff: Task<Void, Never>?
    /// Bumped by every `open` and `close`; a run of an older generation stops.
    private var generation = 0
    private var state: SSHSessionState = .idle
    private var stateObservers: [UUID: AsyncStream<SSHSessionState>.Continuation] = [:]

    public init(terminalID: String, title: String? = nil, connector: any SSHShellConnector,
                policy: SSHReconnectPolicy = SSHReconnectPolicy(), clock: any Clock<Duration> = ContinuousClock()) {
        self.terminalID = terminalID
        self.title = title
        self.connector = connector
        self.policy = policy
        self.clock = clock
    }

    // MARK: TerminalByteSource

    public func open(_ viewport: TerminalViewport) async throws -> AsyncStream<TerminalSourceEvent> {
        await stopRun(finalState: nil)
        self.viewport = viewport
        generation += 1
        let (stream, continuation) = AsyncStream.makeStream(of: TerminalSourceEvent.self, bufferingPolicy: .bufferingOldest(128))
        self.continuation = continuation
        if let title { continuation.yield(.title(title)) }
        let generation = self.generation
        run = Task { await self.connectLoop(generation) }
        return stream
    }

    public func send(_ input: Data) async throws {
        guard state == .live, let channel else { throw FeatureSourceError.offline }
        try await channel.write(input)
    }

    public func viewportChanged(_ viewport: TerminalViewport) async {
        self.viewport = viewport
        await pushWindowChange()
    }

    public func requestSnapshot(_ request: SnapshotRequest) async throws {}

    public func close() async {
        await stopRun(finalState: .closed)
    }

    // MARK: State

    /// The current state first, then every change.
    public func states() -> AsyncStream<SSHSessionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: SSHSessionState.self, bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        stateObservers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    public var currentState: SSHSessionState { state }

    /// Skips the remaining backoff (a user tap, or the app returned to the
    /// foreground). Does nothing unless a reconnect is waiting.
    public func retryNow() {
        backoff?.cancel()
    }

    // MARK: - Private

    private func connectLoop(_ generation: Int) async {
        var attempt = 0
        while isCurrent(generation) {
            if attempt == 0 { setState(.connecting) }
            let opened: any SSHShellChannel
            do {
                opened = try await connector.openShell(cols: viewport.cols, rows: viewport.rows)
            } catch {
                let failure = SSHSessionFailure(error)
                guard isCurrent(generation) else { return }
                guard failure.isRetryable else { return finish(.failed(failure), generation) }
                attempt += 1
                guard await waitBeforeRetry(attempt, generation) else { return }
                continue
            }
            guard isCurrent(generation) else {
                await opened.close()
                return
            }
            channel = opened
            serverGrid = (viewport.cols, viewport.rows)
            attempt = 0
            setState(.live)
            continuation?.yield(.path(.direct, rttMilliseconds: nil))
            // A resize that raced the connect reaches the server now.
            await pushWindowChange()

            var exitStatus: Int?
            var exited = false
            for await event in opened.events {
                guard isCurrent(generation) else { break }
                switch event {
                case .stdout(let data), .stderr(let data):
                    guard emit(data) else {
                        // Dropped terminal bytes cannot be skipped safely. End
                        // this viewer; a fresh attach will hydrate owner state.
                        await opened.close()
                        channel = nil
                        serverGrid = nil
                        return finish(.failed(.network), generation)
                    }
                case .exitStatus(let status):
                    exitStatus = status
                    exited = true
                case .exitSignal:
                    exited = true
                case .closed:
                    break
                }
            }
            await opened.close()
            guard isCurrent(generation) else { return }
            channel = nil
            serverGrid = nil
            if exited { return finish(.exited(status: exitStatus), generation) }
            attempt += 1
            guard await waitBeforeRetry(attempt, generation) else { return }
        }
    }

    /// Waits out the backoff for `attempt`; false when retries ran out or
    /// the run was replaced.
    private func waitBeforeRetry(_ attempt: Int, _ generation: Int) async -> Bool {
        guard let delay = policy.delay(beforeAttempt: attempt) else {
            finish(.failed(.network), generation)
            return false
        }
        setState(.reconnecting(attempt: attempt, delay: delay))
        let clock = self.clock
        let wait = Task<Void, Never> {
            // wakeup-allow: one-shot reconnect backoff after a dropped connection, injected clock, cancelled by retryNow/close
            try? await clock.sleep(for: delay)
        }
        backoff = wait
        await wait.value
        backoff = nil
        return isCurrent(generation)
    }

    private func pushWindowChange() async {
        guard state == .live, let channel else { return }
        let grid = (cols: viewport.cols, rows: viewport.rows)
        if let serverGrid, serverGrid == grid { return }
        serverGrid = grid
        try? await channel.resize(cols: grid.cols, rows: grid.rows)
    }

    private func emit(_ data: Data) -> Bool {
        guard let continuation else { return false }
        for offset in stride(from: 0, to: data.count, by: 16 * 1024) {
            let chunk = data.subdata(in: offset..<min(offset + 16 * 1024, data.count))
            guard case .enqueued = continuation.yield(.bytes(chunk)) else { return false }
        }
        return true
    }

    private func finish(_ final: SSHSessionState, _ generation: Int) {
        guard isCurrent(generation) else { return }
        setState(final)
        continuation?.yield(.closed(reason: Self.reason(final)))
        continuation?.finish()
        continuation = nil
    }

    private func stopRun(finalState: SSHSessionState?) async {
        generation += 1
        run?.cancel()
        run = nil
        backoff?.cancel()
        backoff = nil
        let channel = self.channel
        self.channel = nil
        serverGrid = nil
        await channel?.close()
        if let finalState {
            setState(finalState)
            continuation?.yield(.closed(reason: Self.reason(finalState)))
        }
        continuation?.finish()
        continuation = nil
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && !Task.isCancelled
    }

    private func setState(_ next: SSHSessionState) {
        guard next != state else { return }
        state = next
        for observer in stateObservers.values { observer.yield(next) }
    }

    private func removeObserver(_ id: UUID) {
        stateObservers[id] = nil
    }

    /// A stable, non-localized reason for `TerminalSourceEvent.closed`.
    static func reason(_ state: SSHSessionState) -> String {
        switch state {
        case .exited(let status): status.map { "exited \($0)" } ?? "exited"
        case .failed(let failure): "failed \(failure)"
        case .closed: "closed"
        case .idle, .connecting, .live, .reconnecting: "ended"
        }
    }
}
