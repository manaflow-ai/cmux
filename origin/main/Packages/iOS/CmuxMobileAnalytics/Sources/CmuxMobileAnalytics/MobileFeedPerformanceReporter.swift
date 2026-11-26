public import CMUXMobileCore
public import Foundation

/// Aggregates visible Feed work and scroll callback pacing without content or row IDs.
///
/// A display-link callback is a CPU scheduling signal, not proof of a rendered
/// frame. Histograms use fixed storage and serialize only once per active window.
@MainActor
public final class MobileFeedPerformanceReporter: MobileFeedPerformanceObserving {
    private struct Window {
        let id = UUID().uuidString.lowercased()
        var gaps = MobileFeedTimingHistogram()
        var budgets = MobileFeedTimingHistogram()
        var stages = Dictionary(uniqueKeysWithValues: MobileFeedUpdateStage.allCases.map {
            ($0, MobileFeedTimingHistogram())
        })
        var gapsOver50 = 0
        var gapsOver100 = 0
        var updatesWhileScrolling = 0
        var itemCount = 0
        var hasActivity: Bool { gaps.count > 0 || stages.values.contains { $0.count > 0 } }
    }

    private let emitter: any AnalyticsEmitting
    private let buildSHA: String?
    private let isSimulator: Bool
    private let consent: any AnalyticsConsentProviding
    private let now: @MainActor @Sendable () -> Double
    private let onAnomaly: @MainActor @Sendable (MobileFeedScrollAnomaly) -> String?
    private let consentGate: AnalyticsConsentGenerationGate
    private let consentObserver: AnalyticsConsentRevocationObserver
    private let cadence: Duration
    private let clock: any Clock<Duration>
    private var consentTask: Task<Void, Never>?
    private var cadenceTask: Task<Void, Never>?
    private var window = Window()
    private var generation: UInt64 = 0
    private var startedAt: Double?
    private var previousCallback: Double?
    private var enabled = false
    private var eligibleSince: Double?
    private var visible = false
    private var foreground = true
    private var scrolling = false
    private var currentItemCount = 0
    private var pendingAnomaly: MobileFeedScrollAnomaly?
    private var lastAnomalyAt: Double?

    /// Creates an opt-out-aware reporter; the anomaly bridge runs only after scrolling settles.
    ///
    /// - Parameters:
    ///   - emitter: The authenticated operational emitter, not product analytics.
    ///   - consent: Shared live telemetry permission.
    ///   - buildSHA: Signed bundle source revision; malformed values are omitted.
    ///   - isSimulator: Separates simulator pacing from device observations.
    ///   - notificationCenter: Delivers consent changes; injectable for tests.
    ///   - cadence: Aggregate interval, ten seconds in production.
    ///   - clock: Cancellable aggregate cadence clock, injectable for tests.
    ///   - now: Monotonic seconds, injectable for deterministic tests.
    ///   - onAnomaly: Optional Sentry bridge returning its event ID; called at most once per minute.
    public init(
        emitter: any AnalyticsEmitting,
        consent: any AnalyticsConsentProviding,
        buildSHA: String? = nil,
        isSimulator: Bool = false,
        notificationCenter: NotificationCenter = .default,
        cadence: Duration = .seconds(10),
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @MainActor @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        onAnomaly: @escaping @MainActor @Sendable (MobileFeedScrollAnomaly) -> String? = { _ in nil }
    ) {
        self.buildSHA = buildSHA.flatMap { value in
            value.count == 40 && value.allSatisfy { $0.isHexDigit } ? value.lowercased() : nil
        }
        self.isSimulator = isSimulator
        self.emitter = emitter
        self.consent = consent
        self.now = now
        self.cadence = max(.milliseconds(1), cadence)
        self.clock = clock
        self.onAnomaly = onAnomaly
        let gate = AnalyticsConsentGenerationGate(isEnabled: consent.isTelemetryEnabled)
        consentGate = gate
        let changes = AsyncStream<AnalyticsConsentSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        consentObserver = AnalyticsConsentRevocationObserver(
            notificationCenter: notificationCenter,
            consent: consent,
            generationGate: gate,
            onConsentChange: { changes.continuation.yield($0) }
        )
        consentTask = Task { [weak self] in
            for await _ in changes.stream {
                guard let self else { return }
                self.reconcileConsent()
            }
        }
    }

    deinit {
        consentTask?.cancel()
        cadenceTask?.cancel()
    }

    /// Reads the cached permission gate without consulting UserDefaults per frame.
    public var isSamplingEnabled: Bool { enabled && visible && foreground && consentGate.snapshot().isEnabled }

    /// Remote rollout gate; disabling discards pending windows and incidents immediately.
    public func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            startCadenceIfNeeded()
        } else {
            window = Window()
            pendingAnomaly = nil
            previousCallback = nil
            scrolling = false
            eligibleSince = nil
            cadenceTask?.cancel()
            cadenceTask = nil
        }
    }

    /// Stops sampling across inactive/background intervals and flushes completed work.
    public func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        if !active { endVisibleInterval() }
        if active { startCadenceIfNeeded() }
    }

    /// Updates Feed visibility and a bounded retained item count.
    public func setVisible(_ visible: Bool, itemCount: Int) {
        reconcileConsent()
        if !visible { endVisibleInterval() }
        self.visible = visible
        currentItemCount = min(10_000, max(0, itemCount))
        if isSamplingEnabled {
            window.itemCount = max(window.itemCount, currentItemCount)
            startCadenceIfNeeded()
        }
    }

    /// Resets timing at every gesture boundary, excluding idle gaps.
    public func setScrolling(_ scrolling: Bool) {
        reconcileConsent()
        guard self.scrolling != scrolling else { return }
        self.scrolling = scrolling && isSamplingEnabled
        previousCallback = nil
        if !self.scrolling { reportPendingAnomaly() }
    }

    /// Records callback pacing at the screen's actual requested cadence.
    public func callback(at timestamp: Double, expectedInterval: Double) {
        guard isSamplingEnabled, scrolling, consentGate.snapshot().generation == generation,
              timestamp.isFinite, expectedInterval.isFinite, expectedInterval > 0 else {
            previousCallback = nil
            return
        }
        defer { previousCallback = timestamp }
        guard let previousCallback, timestamp > previousCallback else { return }
        let elapsed = timestamp - previousCallback
        window.gaps.record(seconds: elapsed)
        window.budgets.record(seconds: expectedInterval)
        if elapsed > 0.050 { window.gapsOver50 += 1 }
        if elapsed > 0.100 { window.gapsOver100 += 1 }
    }

    /// Records completed stage work only while the Feed is visible and foregrounded.
    public func updateCompleted(stage: MobileFeedUpdateStage, startedAt: Double, endedAt: Double, itemCount: Int) {
        let elapsed = endedAt - startedAt
        reconcileConsent()
        guard isSamplingEnabled, elapsed.isFinite, elapsed >= 0,
              let eligibleSince, startedAt >= eligibleSince, endedAt <= now() else { return }
        window.stages[stage]?.record(seconds: elapsed)
        window.itemCount = max(window.itemCount, min(10_000, max(0, itemCount)))
        if scrolling, stage == .apply { window.updatesWhileScrolling += 1 }
    }

    /// Emits any partial aggregate and flushes the operational emitter on background.
    public func flush() async {
        emitWindow()
        await emitter.flush()
    }

    private func reconcileConsent() {
        let base = consentGate.snapshot()
        let snapshot = consentGate.synchronize(observedEnabled: consent.isTelemetryEnabled, basedOn: base) { _ in }
        guard generation != snapshot.generation || !snapshot.isEnabled else { return }
        generation = snapshot.generation
        window = Window()
        pendingAnomaly = nil
        previousCallback = nil
        startedAt = nil
        eligibleSince = nil
        scrolling = false
        cadenceTask?.cancel()
        cadenceTask = nil
        if snapshot.isEnabled { startCadenceIfNeeded() }
    }

    private func startCadenceIfNeeded() {
        guard isSamplingEnabled, cadenceTask == nil else { return }
        window.itemCount = currentItemCount
        startedAt = now()
        eligibleSince = startedAt
        let cadence = cadence
        let clock = clock
        cadenceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: cadence) } catch { return }
                self?.emitWindow()
            }
        }
    }

    private func endVisibleInterval() {
        scrolling = false
        previousCallback = nil
        emitWindow()
        reportPendingAnomaly()
        cadenceTask?.cancel()
        cadenceTask = nil
        startedAt = nil
        eligibleSince = nil
    }

    private func emitWindow() {
        reconcileConsent()
        guard enabled, consentGate.snapshot().isEnabled else { return }
        let snapshot = window
        window = Window()
        window.itemCount = currentItemCount
        let timestamp = now()
        let elapsed = max(0, timestamp - (startedAt ?? timestamp))
        startedAt = timestamp
        guard snapshot.hasActivity else { return }
        var properties: [String: AnalyticsValue] = [
            "schema_version": .int(1),
            "window_id": .string(snapshot.id),
            "window_ms": .int(Int(min(60_000, elapsed * 1_000))),
            "item_count": .int(snapshot.itemCount),
            "callback_count": .int(snapshot.gaps.count),
            "callback_gap_histogram": .string(snapshot.gaps.encoded),
            "callback_budget_histogram": .string(snapshot.budgets.encoded),
            "callback_gap_max_ms": .int(snapshot.gaps.maximumMilliseconds),
            "scroll_observed_ms": .int(snapshot.gaps.totalMicroseconds / 1_000),
            "gaps_over_50ms": .int(snapshot.gapsOver50),
            "gaps_over_100ms": .int(snapshot.gapsOver100),
            "updates_while_scrolling": .int(snapshot.updatesWhileScrolling),
        ]
        for stage in MobileFeedUpdateStage.allCases {
            guard let histogram = snapshot.stages[stage] else { continue }
            properties["\(stage.rawValue)_histogram"] = .string(histogram.encoded)
            properties["\(stage.rawValue)_max_ms"] = .int(histogram.maximumMilliseconds)
        }
        properties["is_simulator"] = .bool(isSimulator)
        if let buildSHA { properties["build_sha"] = .string(buildSHA) }
        emitter.capture("ios_feed_performance_window", properties)
        if snapshot.gapsOver100 > 0 {
            let anomaly = MobileFeedScrollAnomaly(
                windowID: snapshot.id,
                maxGapMilliseconds: snapshot.gaps.maximumMilliseconds,
                callbackCount: snapshot.gaps.count,
                itemCount: snapshot.itemCount
            )
            if anomaly.maxGapMilliseconds >= (pendingAnomaly?.maxGapMilliseconds ?? 0) {
                pendingAnomaly = anomaly
            }
        }
        if !scrolling { reportPendingAnomaly() }
    }

    private func reportPendingAnomaly() {
        guard let anomaly = pendingAnomaly else { return }
        pendingAnomaly = nil
        guard enabled, foreground, consentGate.snapshot().generation == generation,
              consentGate.snapshot().isEnabled, consent.isTelemetryEnabled else { return }
        let timestamp = now()
        if let lastAnomalyAt, timestamp - lastAnomalyAt < 60 { return }
        lastAnomalyAt = timestamp
        var properties: [String: AnalyticsValue] = [
            "schema_version": .int(1),
            "window_id": .string(anomaly.windowID),
            "callback_gap_max_ms": .int(anomaly.maxGapMilliseconds),
            "callback_count": .int(anomaly.callbackCount),
            "item_count": .int(anomaly.itemCount),
        ]
        if let eventID = onAnomaly(anomaly) { properties["sentry_event_id"] = .string(eventID) }
        properties["is_simulator"] = .bool(isSimulator)
        if let buildSHA { properties["build_sha"] = .string(buildSHA) }
        emitter.capture("ios_feed_scroll_anomaly", properties)
    }
}
