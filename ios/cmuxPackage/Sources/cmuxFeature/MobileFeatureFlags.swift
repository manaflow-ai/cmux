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
        ClientConfigFlag<Bool>.mobileTerminalFilesChipEnabledRelease

    private static var terminalFilesChipCacheKey: String {
        "cmux.mobile.flags.remote." + terminalFilesChipFlag.key
    }
    private static let refreshInterval: Duration = .seconds(5 * 60)

    /// Whether the chip and its count-only artifact scan are enabled.
    public private(set) var terminalFilesChipEnabled: Bool

    @ObservationIgnored private let loader: any ClientConfigLoading
    @ObservationIgnored private let request: ClientConfigRequest
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let refreshClock: any Clock<Duration>
    @ObservationIgnored private var refreshLoopTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false

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
    }

    /// Starts immediate and five-minute refreshes. Calling this again is a no-op.
    public func start() {
        guard refreshLoopTask == nil else { return }
        let clock = refreshClock
        refreshLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refresh()
                do {
                    try await clock.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// Cancels periodic refresh work when the owning app graph is torn down.
    public func stop() {
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
    }

    /// Refreshes flags without allowing a failed request to erase the cache.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard !Task.isCancelled,
              let config = try? await loader.load(request),
              !Task.isCancelled,
              !config.errorsWhileComputingFlags else { return }

        let enabled = config.value(Self.terminalFilesChipFlag)
        if terminalFilesChipEnabled != enabled {
            terminalFilesChipEnabled = enabled
        }
        if Self.storedBool(forKey: Self.terminalFilesChipCacheKey, defaults: defaults) != enabled {
            defaults.set(enabled, forKey: Self.terminalFilesChipCacheKey)
        }
    }

    private static func storedBool(forKey key: String, defaults: UserDefaults) -> Bool? {
        guard let value = defaults.object(forKey: key) else { return nil }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }
}
