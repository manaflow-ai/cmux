import Foundation

/// Orchestrates protocol-v6 byte attachment, input, and latest-interaction sizing.
public actor CmuxFrontendSession {
    private let client: CmuxProtocolClient
    private let configuration: CmuxConnectionConfiguration
    private let resizeDebounce: Duration
    private var surface: UInt64?
    private var protocolVersion: UInt32?
    private var remoteSize: CmuxSurfaceSize?
    private var resizeTask: Task<Void, Never>?

    /// Creates a frontend session from injected protocol pieces.
    /// - Parameters:
    ///   - client: The request/event protocol client.
    ///   - configuration: WebSocket endpoint and token.
    ///   - resizeDebounce: The bounded window-resize coalescing delay.
    public init(
        client: CmuxProtocolClient,
        configuration: CmuxConnectionConfiguration,
        resizeDebounce: Duration = .milliseconds(120)
    ) {
        self.client = client
        self.configuration = configuration
        self.resizeDebounce = resizeDebounce
    }

    /// Connects, negotiates protocol 6+, labels the client, selects a PTY, and attaches it.
    /// - Parameters:
    ///   - hostname: The client name reported to cmux-tui.
    ///   - preferredSurface: An optional surface override used by diagnostics.
    /// - Returns: The selected tree and attachment summary.
    public func connect(
        hostname: String,
        preferredSurface: UInt64? = nil
    ) async throws -> CmuxFrontendStartup {
        try await client.connect(token: configuration.token)
        let identify = try await client.identify()
        guard identify.app == "cmux-tui", identify.protocol >= 6 else {
            throw CmuxProtocolError.incompatibleServer(
                "expected cmux-tui protocol >= 6, got \(identify.app) protocol \(identify.protocol)"
            )
        }

        try await client.setClientInfo(name: hostname, kind: "swift")
        let tree = try await client.listWorkspaces()
        guard let selected = preferredSurface ?? tree.selectedSurface() else {
            throw CmuxProtocolError.noActivePTYSurface
        }

        surface = selected
        protocolVersion = identify.protocol
        try await client.attachSurface(selected, includeByteMode: identify.protocol >= 7)
        return CmuxFrontendStartup(
            workspaceNames: tree.workspaces.map(\.name),
            surface: selected,
            protocolVersion: identify.protocol
        )
    }

    /// Returns the ordered byte-attach event stream.
    /// - Returns: Buffered attach events from the protocol client.
    public func events() async -> AsyncStream<CmuxAttachEvent> {
        await client.events()
    }

    /// Sends libghostty-generated input bytes to the attached surface.
    /// - Parameter data: Raw terminal input bytes.
    public func sendInput(_ data: Data) async {
        guard let surface else { return }
        try? await client.sendBytes(data, surface: surface)
    }

    /// Sends UTF-8 text to the attached surface and waits for acknowledgement.
    /// - Parameter text: Text to write to the PTY.
    public func sendText(_ text: String) async throws {
        guard let surface else {
            throw CmuxProtocolError.transportState("no attached surface")
        }
        try await client.sendText(text, surface: surface)
    }

    /// Records authoritative replay sizing before rendering that replay.
    /// - Parameter event: The next ordered attachment event.
    public func observe(_ event: CmuxAttachEvent) {
        switch event {
        case let .initialReplay(_, columns, rows, _, _),
             let .resizedReplay(_, columns, rows, _):
            remoteSize = CmuxSurfaceSize(cols: columns, rows: rows)
        case .detached:
            surface = nil
        case .output, .colorsChanged, .other:
            break
        }
    }

    /// Coalesces a user-driven window resize before applying the latest grid.
    /// - Parameters:
    ///   - columns: The visible Ghostty column count.
    ///   - rows: The visible Ghostty row count.
    public func scheduleResize(columns: UInt16, rows: UInt16) {
        let requested = CmuxSurfaceSize(cols: columns, rows: rows)
        guard requested != remoteSize else { return }

        resizeTask?.cancel()
        let delay = resizeDebounce
        resizeTask = Task { [weak self] in
            do {
                // A bounded delay is the intended debounce behavior and is cancelled by newer interactions.
                try await ContinuousClock().sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.resizeNow(requested)
        }
    }

    /// Closes the frontend connection.
    public func close() async {
        resizeTask?.cancel()
        resizeTask = nil
        await client.close()
    }

    private func resizeNow(_ requested: CmuxSurfaceSize) async {
        guard requested != remoteSize, let surface else { return }
        do {
            try await client.resizeSurface(
                surface,
                columns: requested.cols,
                rows: requested.rows
            )
            remoteSize = requested
        } catch {
            return
        }
    }
}
