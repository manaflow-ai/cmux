import CMUXMobileCore
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

/// Owns endpoint activation readiness and all waiters for the latest
/// lifecycle revision.
@MainActor
final class MobileIrohConnectionReadinessOwner {
    private var pendingRevision: UInt64?
    private var settledOutcome = MobileIrohConnectionReadinessOutcome.inactive
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var isPending: Bool { pendingRevision != nil }

    func begin(revision: UInt64) {
        let supersededPrevious =
            pendingRevision != nil && pendingRevision != revision
        pendingRevision = revision
        if supersededPrevious {
            // Existing waiters must re-evaluate against the new revision.
            // Leaving them parked on the superseded lifecycle leaks every
            // connection entrypoint if that old task never completes.
            resumeWaiters()
        }
    }

    @discardableResult
    func abandon(revision: UInt64) -> Bool {
        guard pendingRevision == revision else { return false }
        pendingRevision = nil
        settledOutcome = .inactive
        resumeWaiters()
        return true
    }

    @discardableResult
    func complete(
        revision: UInt64,
        outcome: MobileIrohConnectionReadinessOutcome = .ready
    ) -> Bool {
        guard pendingRevision == revision else { return false }
        pendingRevision = nil
        settledOutcome = outcome
        resumeWaiters()
        return true
    }

    func wait(
        now: @escaping @MainActor () -> Date
    ) async -> MobileIrohConnectionReadinessOutcome {
        while isPending {
            guard !Task.isCancelled else { return .inactive }
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard isPending, !Task.isCancelled else {
                        continuation.resume()
                        return
                    }
                    waiters[waiterID] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelWaiter(waiterID)
                }
            }
            guard !Task.isCancelled else { return .inactive }
        }
        return settledOutcome
    }

    private func resumeWaiters() {
        let continuations = Array(waiters.values)
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
