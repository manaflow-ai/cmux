import Foundation
public import Logging

/// Watches for "stuck agent" conditions: a surface that has not produced
/// any new output for longer than `policy.watchdogStuckMinutes`. When the
/// threshold is crossed the iOS app fires a time-sensitive local
/// notification ("Claude is stuck on workspace X — open?") so the user can
/// jump in.
///
/// State is driven by `surface.input_sent` / `surface.key_sent` events
/// plus the snapshot's `lastNotification` timestamps. We deliberately do
/// NOT poll `read-screen` from the watchdog — that work belongs to the
/// foreground terminal view.
public actor AgentWatchdog {
    public struct Configuration: Sendable {
        public var stuckThreshold: Duration
        public var pollInterval: Duration
        public var onStuckSurface: @Sendable (SurfaceID, WorkspaceID?) async -> Void

        public init(
            stuckThreshold: Duration = .seconds(5 * 60),
            pollInterval: Duration = .seconds(60),
            onStuckSurface: @escaping @Sendable (SurfaceID, WorkspaceID?) async -> Void
        ) {
            self.stuckThreshold = stuckThreshold
            self.pollInterval = pollInterval
            self.onStuckSurface = onStuckSurface
        }
    }

    private let config: Configuration
    private let log: Logger
    private var lastActivity: [SurfaceID: (timestamp: Date, workspaceID: WorkspaceID?)] = [:]
    private var alerted: Set<SurfaceID> = []
    private var loopTask: Task<Void, Never>?

    public init(
        configuration: Configuration,
        logger: Logger = CmuxLog.make("watchdog")
    ) {
        self.config = configuration
        self.log = logger
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.loop()
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    public func touch(surfaceID: SurfaceID, workspaceID: WorkspaceID?) {
        lastActivity[surfaceID] = (Date(), workspaceID)
        alerted.remove(surfaceID)
    }

    public func observe(event: CmuxEventFrame.Event) {
        guard event.category == "surface" || event.category == "agent" else { return }
        guard let surfaceID = event.surfaceID else { return }
        touch(surfaceID: surfaceID, workspaceID: event.workspaceID)
    }

    private func loop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: config.pollInterval)
            guard !Task.isCancelled else { break }
            await scan()
        }
    }

    private func scan() async {
        let now = Date()
        let thresholdComponents = config.stuckThreshold.components
        let threshold = Double(thresholdComponents.seconds)
            + Double(thresholdComponents.attoseconds) / 1.0e18
        for (surfaceID, value) in lastActivity {
            if alerted.contains(surfaceID) { continue }
            if now.timeIntervalSince(value.timestamp) > threshold {
                alerted.insert(surfaceID)
                await config.onStuckSurface(surfaceID, value.workspaceID)
            }
        }
    }
}
