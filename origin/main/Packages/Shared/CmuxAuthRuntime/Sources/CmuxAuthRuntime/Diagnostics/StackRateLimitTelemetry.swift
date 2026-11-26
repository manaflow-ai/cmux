public import Foundation
import os
import StackAuth

/// Which auth step the sign-in service answered with 429.
public enum StackAuthRateLimitPhase: String, Sendable, CaseIterable {
    /// Completing a browser sign-in callback (the user fetch).
    case signInCompletion = "sign_in_completion"
    /// The refresh-token exchange.
    case tokenRefresh = "token_refresh"
    /// The session check: get user and list teams.
    case sessionCheck = "session_check"
    /// Any other sign-in service call.
    case other
}

/// One telemetry record about sign-in service rate limiting. Carries no
/// account, token, email or query data.
public struct StackRateLimitTelemetryEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A 429 was observed. `endpoint` is a path with ids replaced by `ID`.
        case rateLimited(retryAfterSeconds: Int?, backoffSeconds: Int, attempt: Int, bodyKind: String, endpoint: String)
        /// The phase succeeded after a rate-limited period that lasted this long.
        case recovered(limitedForSeconds: Int)
    }

    public let phase: StackAuthRateLimitPhase
    public let kind: Kind
    public let date: Date
}

/// Turns 429s from the sign-in service into coalesced telemetry events.
///
/// Telemetry must never amplify an incident: per phase, at most one
/// rate-limited event is emitted per backoff window (the larger of the
/// chosen backoff, the server's `Retry-After`, and ``minimumWindow``). The
/// first success of a phase after a rate-limited period emits one recovered
/// event. Events raised before a sink is attached wait in a bounded buffer.
public final class StackRateLimitTelemetry: Sendable {
    /// The process-wide instance. First access routes the SDK's refresh and
    /// unscoped-request 429s here.
    public static let shared: StackRateLimitTelemetry = {
        let telemetry = StackRateLimitTelemetry()
        StackAuthRateLimitReporting.setObserver(SDKObserver(telemetry: telemetry))
        return telemetry
    }()

    /// The shortest coalescing window, whatever the backoff.
    static let minimumWindow: Duration = .seconds(10)
    /// The window for a 429 no app flow reports (``StackAuthRateLimitPhase/other``)
    /// when the server sent no `Retry-After`.
    static let unscopedWindow: Duration = .seconds(60)
    /// Events kept while no sink is attached.
    static let pendingLimit = 32
    /// A limited period with no 429 for this long past its window is over
    /// without a success (the flow gave up, signed out, or lost its session).
    /// It ends silently, so a later success is not reported as a recovery and
    /// a later 429 starts a new period.
    static let staleAfter: Duration = .seconds(30 * 60)

    private struct PhaseState {
        var limitedSince: ContinuousClock.Instant
        var quietUntil: ContinuousClock.Instant
        var observed: Int
    }

    private struct State {
        var phases: [StackAuthRateLimitPhase: PhaseState] = [:]
        var sink: (@Sendable (StackRateLimitTelemetryEvent) -> Void)?
        var pending: [StackRateLimitTelemetryEvent] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let now: @Sendable () -> ContinuousClock.Instant
    private let date: @Sendable () -> Date

    /// Creates an instance. Only ``shared`` receives SDK signals.
    public init(
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        date: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        self.date = date
    }

    /// Attaches the consumer and hands it any buffered events; `nil` detaches.
    public func setSink(_ sink: (@Sendable (StackRateLimitTelemetryEvent) -> Void)?) {
        let pending = state.withLock { state -> [StackRateLimitTelemetryEvent] in
            state.sink = sink
            guard sink != nil else { return [] }
            defer { state.pending.removeAll() }
            return state.pending
        }
        if let sink { pending.forEach(sink) }
    }

    /// Records a 429 that an app flow handles with its own retry policy.
    /// - Parameters:
    ///   - phase: The flow that was refused.
    ///   - rateLimit: The recognized 429.
    ///   - backoff: The wait the flow chose before its next attempt; zero when it gives up.
    ///   - attempt: The flow's consecutive rate-limited attempt, starting at 1.
    public func rateLimited(
        _ phase: StackAuthRateLimitPhase,
        rateLimit: AuthRateLimit,
        backoff: Duration,
        attempt: Int
    ) {
        record(
            phase,
            endpoint: rateLimit.endpoint,
            bodyKind: rateLimit.bodyKind,
            retryAfter: rateLimit.retryAfter,
            backoff: backoff,
            attempt: attempt
        )
    }

    /// Records that `phase` succeeded. Emits one recovered event when the
    /// phase was rate limited; otherwise does nothing.
    public func succeeded(_ phase: StackAuthRateLimitPhase) {
        let instant = now()
        let event = state.withLock { state -> StackRateLimitTelemetryEvent? in
            guard let limited = state.phases.removeValue(forKey: phase),
                  instant < limited.quietUntil + Self.staleAfter
            else { return nil }
            let seconds = Self.wholeSeconds(instant - limited.limitedSince)
            return StackRateLimitTelemetryEvent(phase: phase, kind: .recovered(limitedForSeconds: seconds), date: date())
        }
        if let event { deliver(event) }
    }

    func record(
        _ phase: StackAuthRateLimitPhase,
        endpoint: String,
        bodyKind: String,
        retryAfter: Duration?,
        backoff: Duration,
        attempt: Int?
    ) {
        let instant = now()
        let event = state.withLock { state -> StackRateLimitTelemetryEvent? in
            var phaseState = state.phases[phase]
                .flatMap { instant < $0.quietUntil + Self.staleAfter ? $0 : nil }
                ?? PhaseState(limitedSince: instant, quietUntil: instant, observed: 0)
            phaseState.observed += 1
            defer { state.phases[phase] = phaseState }
            guard instant >= phaseState.quietUntil else { return nil }
            let window = max(backoff, retryAfter ?? .zero, Self.minimumWindow)
            phaseState.quietUntil = instant + window
            return StackRateLimitTelemetryEvent(
                phase: phase,
                kind: .rateLimited(
                    retryAfterSeconds: retryAfter.map(Self.wholeSeconds),
                    backoffSeconds: Self.wholeSeconds(backoff),
                    attempt: max(1, attempt ?? phaseState.observed),
                    bodyKind: bodyKind,
                    endpoint: endpoint
                ),
                date: date()
            )
        }
        if let event { deliver(event) }
    }

    private func deliver(_ event: StackRateLimitTelemetryEvent) {
        let sink = state.withLock { state -> (@Sendable (StackRateLimitTelemetryEvent) -> Void)? in
            if let sink = state.sink { return sink }
            if state.pending.count < Self.pendingLimit { state.pending.append(event) }
            return nil
        }
        sink?(event)
    }

    private static func wholeSeconds(_ duration: Duration) -> Int {
        let seconds = duration.components.seconds
        return Int(min(max(seconds, 0), 30 * 86_400))
    }

    private static func duration(seconds: TimeInterval?) -> Duration? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return .milliseconds(Int64(min(seconds, 86_400) * 1000))
    }

    /// Adapts the SDK's process-wide signals to this instance.
    private struct SDKObserver: StackAuthRateLimitObserver {
        let telemetry: StackRateLimitTelemetry

        func stackAuthDidRateLimit(_ observation: StackAuthRateLimitObservation) {
            let retryAfter = StackRateLimitTelemetry.duration(seconds: observation.retryAfterSeconds)
            if observation.isTokenRefresh {
                telemetry.record(
                    .tokenRefresh,
                    endpoint: observation.endpoint,
                    bodyKind: observation.bodyKind.rawValue,
                    retryAfter: retryAfter,
                    backoff: StackRateLimitTelemetry.duration(seconds: observation.refreshBackoffSeconds) ?? .zero,
                    attempt: observation.refreshAttempt
                )
            } else {
                // No app flow retries this call on a schedule; the window is
                // how long this instance stays quiet about it.
                telemetry.record(
                    .other,
                    endpoint: observation.endpoint,
                    bodyKind: observation.bodyKind.rawValue,
                    retryAfter: retryAfter,
                    backoff: retryAfter ?? StackRateLimitTelemetry.unscopedWindow,
                    attempt: nil
                )
            }
        }

        func stackAuthTokenRefreshDidRecover() {
            telemetry.succeeded(.tokenRefresh)
        }

        func stackAuthRequestDidSucceed() {
            telemetry.succeeded(.other)
        }
    }
}
