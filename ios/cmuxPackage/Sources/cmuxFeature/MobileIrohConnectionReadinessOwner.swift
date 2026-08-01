import CMUXMobileCore
import CmuxIrohTransport
import Foundation

/// A stable, retry-aware failure returned by every connection entrypoint after
/// one endpoint activation fails.
struct MobileIrohRuntimePreparationError:
    CmxRetryAfterProviding,
    DiagnosticFailureProviding,
    Equatable
{
    let diagnosticFailureKind: DiagnosticFailureKind
    let retryAfterSeconds: Int?
}

enum MobileIrohConnectionReadinessOutcome: Equatable, Sendable {
    case inactive
    case ready
    case failed(MobileIrohRuntimePreparationError)

    var failureKind: DiagnosticFailureKind {
        if case let .failed(error) = self {
            return error.diagnosticFailureKind
        }
        return .endpointUnavailable
    }
}

/// Owns endpoint activation readiness, failure backoff, and all waiters for the
/// latest lifecycle revision.
///
/// The retry gate is the single client-side bound on broker traffic: every
/// dial, discovery, and preparation re-triggers a reconcile while no runtime
/// exists, and without one armed window a wedged phone re-ran registration,
/// discovery, and relay-policy every few seconds indefinitely. The ladder's
/// foreground cap keeps the armed nap short while the app is visible, and
/// ``resetRetryCooldown()`` lifts it entirely on a real state change.
@MainActor
final class MobileIrohConnectionReadinessOwner {
    /// One armed retry window: the caller-facing failure plus the exact drawn
    /// delay for privacy-safe diagnostics.
    struct ScheduledRetry {
        let failure: MobileIrohRuntimePreparationError
        let delay: TimeInterval
    }

    private let retryBackoff: CmxIrohReconnectBackoff
    private var pendingRevision: UInt64?
    private var settledOutcome = MobileIrohConnectionReadinessOutcome.inactive
    private var retryAccountID: String?
    private var retryAt: Date?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(retryBackoff: CmxIrohReconnectBackoff = CmxIrohReconnectBackoff()) {
        self.retryBackoff = retryBackoff
    }

    var isPending: Bool { pendingRevision != nil }
    var pendingWaiterCount: Int { waiters.count }

    func begin(revision: UInt64) {
        if let pendingRevision, revision < pendingRevision { return }
        pendingRevision = revision
    }

    @discardableResult
    func complete(
        revision: UInt64,
        outcome: MobileIrohConnectionReadinessOutcome = .ready
    ) -> Bool {
        guard let activeRevision = pendingRevision,
              activeRevision <= revision else {
            return false
        }
        pendingRevision = nil
        settledOutcome = outcome
        switch outcome {
        case .failed:
            break
        case .inactive, .ready:
            retryBackoff.reset()
            retryAccountID = nil
            retryAt = nil
        }
        resumeWaiters()
        return true
    }

    @discardableResult
    func finishPendingRevision(revision: UInt64) -> Bool {
        guard let activeRevision = pendingRevision,
              activeRevision <= revision else {
            return false
        }
        pendingRevision = nil
        resumeWaiters()
        return true
    }

    @discardableResult
    func completeFailure(
        revision: UInt64,
        accountID: String,
        error: any Error,
        retryAfterSeconds: Int?,
        now: Date
    ) -> ScheduledRetry? {
        guard pendingRevision == revision else { return nil }
        if retryAccountID != accountID {
            // A different account never inherits another account's streak.
            retryBackoff.reset()
        }
        let serverFloor = max(
            retryAfterSeconds ?? 0,
            (error as? any CmxRetryAfterProviding)?.retryAfterSeconds ?? 0
        )
        let delay = retryBackoff.nextDelay(
            retryAfterSeconds: serverFloor > 0 ? serverFloor : nil
        )
        retryAccountID = accountID
        retryAt = now.addingTimeInterval(delay)
        pendingRevision = nil
        let failure = MobileIrohRuntimePreparationError(
            diagnosticFailureKind: DiagnosticFailureKind.classify(error),
            retryAfterSeconds: max(1, Int(delay.rounded(.up)))
        )
        settledOutcome = .failed(failure)
        resumeWaiters()
        return ScheduledRetry(failure: failure, delay: delay)
    }

    /// Returns the ladder to its floor and lifts the armed retry gate. Owners
    /// call this on scenePhase-active transitions and network-path changes:
    /// the failure streak belonged to the previous app or network state, so
    /// the next activation attempt must run immediately.
    func resetRetryCooldown() {
        retryBackoff.reset()
        retryAccountID = nil
        retryAt = nil
        if !isPending, case .failed = settledOutcome {
            settledOutcome = .inactive
        }
    }

    func shouldStartActivation(accountID: String, now: Date) -> Bool {
        guard !isPending else { return false }
        return shouldAttemptActivation(accountID: accountID, now: now)
    }

    func shouldAttemptActivation(accountID: String, now: Date) -> Bool {
        guard retryAccountID == accountID, let retryAt else { return true }
        return now >= retryAt
    }

    func wait(
        now: @MainActor () -> Date
    ) async -> MobileIrohConnectionReadinessOutcome {
        if isPending {
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard isPending, !Task.isCancelled else {
                        continuation.resume()
                        return
                    }
                    waiters[waiterID] = continuation
                }
            } onCancel: { [weak self] in
                Task { @MainActor in
                    self?.cancelWaiter(id: waiterID)
                }
            }
        }
        if Task.isCancelled { return .inactive }
        guard case let .failed(failure) = settledOutcome,
              let retryAt else {
            return settledOutcome
        }
        let currentDate = now()
        let remaining = max(
            1,
            Int(retryAt.timeIntervalSince(currentDate).rounded(.up))
        )
        return .failed(MobileIrohRuntimePreparationError(
            diagnosticFailureKind: failure.diagnosticFailureKind,
            retryAfterSeconds: remaining
        ))
    }

    private func cancelWaiter(id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume()
    }

    private func resumeWaiters() {
        let continuations = Array(waiters.values)
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
