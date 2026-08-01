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
@MainActor
final class MobileIrohConnectionReadinessOwner {
    private let retrySchedule: CmxIrohRetrySchedule
    private let jitterUnitInterval: @MainActor () -> Double
    private var pendingRevision: UInt64?
    private var settledOutcome = MobileIrohConnectionReadinessOutcome.inactive
    private var retryAccountID: String?
    private var retryAt: Date?
    private var consecutiveFailureCount = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(
        retrySchedule: CmxIrohRetrySchedule = CmxIrohRetrySchedule(
            initialDelay: 30,
            maximumDelay: 3_600
        ),
        jitterUnitInterval: @escaping @MainActor () -> Double = {
            Double.random(in: 0 ... 1)
        }
    ) {
        self.retrySchedule = retrySchedule
        self.jitterUnitInterval = jitterUnitInterval
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
            retryAccountID = nil
            retryAt = nil
            consecutiveFailureCount = 0
        }
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
    ) -> MobileIrohRuntimePreparationError? {
        guard pendingRevision == revision else { return nil }
        if retryAccountID != accountID {
            consecutiveFailureCount = 0
        }
        let serverFloor = max(
            retryAfterSeconds ?? 0,
            (error as? any CmxRetryAfterProviding)?.retryAfterSeconds ?? 0
        )
        let delay = retrySchedule.delay(
            failureCount: consecutiveFailureCount,
            retryAfterSeconds: serverFloor > 0 ? serverFloor : nil,
            jitterUnitInterval: jitterUnitInterval()
        )
        let boundedDelay = max(1, Int(delay.rounded(.up)))
        retryAccountID = accountID
        retryAt = now.addingTimeInterval(delay)
        consecutiveFailureCount = min(consecutiveFailureCount + 1, 20)
        pendingRevision = nil
        let failure = MobileIrohRuntimePreparationError(
            diagnosticFailureKind: DiagnosticFailureKind.classify(error),
            retryAfterSeconds: boundedDelay
        )
        settledOutcome = .failed(failure)
        resumeWaiters()
        return failure
    }

    func shouldStartActivation(accountID: String, now: Date) -> Bool {
        guard !isPending else { return false }
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
