import CmuxClientConfig
import Foundation
import Observation

/// PostHog-backed runtime feature flags for the iOS app.
///
/// Successful responses replace cached values immediately. Network failures
/// and PostHog evaluation errors preserve the last known value, while a fresh
/// install defaults to the shipping behavior. The app root starts the periodic
/// refresh and also refreshes whenever the scene becomes active.
@MainActor
@Observable
public final class MobileFeatureFlags {
    /// The remote kill switch for the fully integrated terminal Files chip.
    public static let terminalFilesChipFlag =
        ClientConfigFlag<Bool>.iosArtifactChipEnabledRelease
    /// The remote kill switch reverting iOS ≤26 keyboard pinning to the
    /// rebuilt dock path.
    public static let keyboardDockRebuildRevertFlag =
        ClientConfigFlag<Bool>.iosKeyboardDockRebuildRevert

    /// User-defaults key for the last successful remote value.
    private static var terminalFilesChipCacheKey: String {
        "cmux.mobile.flags.remote." + terminalFilesChipFlag.key
    }
    /// User-defaults key for the last successful keyboard-revert value.
    private static var keyboardDockRebuildRevertCacheKey: String {
        "cmux.mobile.flags.remote." + keyboardDockRebuildRevertFlag.key
    }
    /// Delay between foreground refresh opportunities when the app remains active.
    /// Thirty minutes bounds steady-state control-plane traffic across the fleet;
    /// launch and scene-active refreshes keep flag propagation fast where it matters.
    private static let refreshInterval: Duration = .seconds(30 * 60)

    /// Whether the chip and its count-only artifact scan are enabled.
    public private(set) var terminalFilesChipEnabled: Bool
    /// Whether iOS ≤26 terminal keyboard pinning reverts to the rebuilt dock
    /// path. Terminal hosts snapshot this at mount (reopen the workspace to
    /// apply); iOS 27+ ignores it.
    public private(set) var keyboardDockRebuildRevertEnabled: Bool

    /// Control-plane client used to fetch evaluated flags.
    @ObservationIgnored private let loader: any ClientConfigLoading
    /// Stable anonymous evaluation request sent to the control plane.
    @ObservationIgnored private let request: ClientConfigRequest
    /// Persistence for the last known remote value.
    @ObservationIgnored private let defaults: UserDefaults
    /// Injectable clock used by the periodic scheduler and tests.
    @ObservationIgnored private let refreshClock: any Clock<Duration>
    /// The one-shot wait that schedules the next periodic refresh.
    @ObservationIgnored private var periodicRefreshTask: Task<Void, Never>?
    /// The currently running remote load, if any.
    @ObservationIgnored private var refreshOperationTask: Task<Void, Never>?
    /// Whether a trigger arrived while the current load was running.
    @ObservationIgnored private var refreshRequested = false
    /// Callers waiting for the next completed refresh operation.
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    /// Invalidates scheduler work after the owner stops or restarts.
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0
    /// Whether the app root currently owns the periodic scheduler.
    @ObservationIgnored private var isStarted = false

    /// Creates the runtime flag store with an injected control-plane loader.
    public init(
        loader: any ClientConfigLoading,
        request: ClientConfigRequest,
        defaults: UserDefaults = .standard,
        refreshClock: any Clock<Duration> = ContinuousClock()
    ) {
        self.loader = loader
        self.request = request
        self.defaults = defaults
        self.refreshClock = refreshClock
        self.terminalFilesChipEnabled = Self.storedBool(
            forKey: Self.terminalFilesChipCacheKey,
            defaults: defaults
        ) ?? Self.terminalFilesChipFlag.defaultValue
        self.keyboardDockRebuildRevertEnabled = Self.storedBool(
            forKey: Self.keyboardDockRebuildRevertCacheKey,
            defaults: defaults
        ) ?? Self.keyboardDockRebuildRevertFlag.defaultValue
    }

    /// Starts an immediate refresh and a cancellation-aware thirty-minute scheduler.
    /// Calling this again is a no-op.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        requestRefresh()
        scheduleNextPeriodicRefresh(for: lifecycleGeneration)
    }

    /// Cancels periodic refresh work when the owning app graph is torn down.
    public func stop() {
        isStarted = false
        lifecycleGeneration &+= 1
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        refreshOperationTask?.cancel()
        refreshOperationTask = nil
        refreshRequested = false
        let waiters = refreshWaiters
        refreshWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Queues one foreground refresh without creating an unowned task at the call site.
    public func refreshOnForeground() {
        requestRefresh()
    }

    /// Refreshes flags without allowing a failed request to erase the cache.
    public func refresh() async {
        await withCheckedContinuation { continuation in
            refreshWaiters.append(continuation)
            requestRefresh()
        }
    }

    /// Starts the next one-shot clock wait for the current lifecycle generation.
    private func scheduleNextPeriodicRefresh(for generation: UInt64) {
        guard isStarted, periodicRefreshTask == nil else { return }
        let clock = refreshClock
        periodicRefreshTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: Self.refreshInterval)
            } catch {
                return
            }
            guard let self,
                  self.isStarted,
                  self.lifecycleGeneration == generation else { return }
            self.periodicRefreshTask = nil
            self.requestRefresh()
            self.scheduleNextPeriodicRefresh(for: generation)
        }
    }

    /// Coalesces foreground and periodic triggers into one owned operation.
    private func requestRefresh() {
        guard refreshOperationTask == nil else {
            refreshRequested = true
            return
        }
        let generation = lifecycleGeneration
        refreshOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh()
            self.completeRefresh(for: generation)
        }
    }

    /// Performs one remote load and applies only a complete, valid response.
    private func performRefresh() async {
        let loader = self.loader
        let request = self.request
        let config = await Self.loadConfig(loader: loader, request: request)

        guard !Task.isCancelled,
              let config,
              !Task.isCancelled,
              !config.errorsWhileComputingFlags else { return }

        let enabled = config.value(Self.terminalFilesChipFlag)
        if terminalFilesChipEnabled != enabled {
            terminalFilesChipEnabled = enabled
        }
        if Self.storedBool(forKey: Self.terminalFilesChipCacheKey, defaults: defaults) != enabled {
            defaults.set(enabled, forKey: Self.terminalFilesChipCacheKey)
        }

        let revertEnabled = config.value(Self.keyboardDockRebuildRevertFlag)
        if keyboardDockRebuildRevertEnabled != revertEnabled {
            keyboardDockRebuildRevertEnabled = revertEnabled
        }
        if Self.storedBool(
            forKey: Self.keyboardDockRebuildRevertCacheKey,
            defaults: defaults
        ) != revertEnabled {
            defaults.set(revertEnabled, forKey: Self.keyboardDockRebuildRevertCacheKey)
        }
    }

    /// Completes an owned load, resumes callers, and services one queued trigger.
    private func completeRefresh(for generation: UInt64) {
        guard lifecycleGeneration == generation else { return }
        refreshOperationTask = nil
        if refreshRequested {
            refreshRequested = false
            requestRefresh()
            return
        }
        let waiters = refreshWaiters
        refreshWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Loads and decodes client configuration on the concurrent executor.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    private nonisolated static func loadConfig(
        loader: any ClientConfigLoading,
        request: ClientConfigRequest
    ) async -> ClientConfig? {
        try? await loader.load(request)
    }

    /// Reads a cached boolean while tolerating legacy numeric defaults values.
    private static func storedBool(forKey key: String, defaults: UserDefaults) -> Bool? {
        guard let value = defaults.object(forKey: key) else { return nil }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }
}
