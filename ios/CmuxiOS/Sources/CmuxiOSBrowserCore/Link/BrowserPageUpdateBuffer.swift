import CmuxiOSFeatureKit
import os

/// Page updates for one consumer, bounded (E1): each kind (page, page size,
/// cursor, text focus, clipboard) keeps only its newest unread value, so a
/// consumer that stops reading holds at most five updates. Kinds are read in
/// the order they first became unread.
final class BrowserPageUpdateBuffer: Sendable {
    private enum Kind: CaseIterable {
        case page, pageSize, cursor, textFocus, clipboard
    }

    private struct State {
        var slots: [Kind: BrowserPageUpdate] = [:]
        var order: [Kind] = []
        var finished = false
        var waiter: CheckedContinuation<BrowserPageUpdate?, Never>?
    }

    // carve-out: the session actor pushes, the consumer's task pops; one
    // short critical section each, never held across a suspension.
    private let state = OSAllocatedUnfairLock(initialState: State())

    var stream: AsyncStream<BrowserPageUpdate> {
        AsyncStream(unfolding: { [self] in await next() })
    }

    func push(_ update: BrowserPageUpdate) {
        let kind = Self.kind(of: update)
        let waiter = state.withLock { state -> CheckedContinuation<BrowserPageUpdate?, Never>? in
            guard !state.finished else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            if state.slots.updateValue(update, forKey: kind) == nil { state.order.append(kind) }
            return nil
        }
        waiter?.resume(returning: update)
    }

    /// The consumer reads what is unread, then the sequence ends.
    func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<BrowserPageUpdate?, Never>? in
            state.finished = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    func next() async -> BrowserPageUpdate? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<BrowserPageUpdate?, Never>) in
                let taken = state.withLock { state -> BrowserPageUpdate?? in
                    if !state.order.isEmpty {
                        let kind = state.order.removeFirst()
                        return .some(state.slots.removeValue(forKey: kind))
                    }
                    if state.finished || Task.isCancelled { return .some(nil) }
                    state.waiter = continuation
                    return nil
                }
                if let taken { continuation.resume(returning: taken) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<BrowserPageUpdate?, Never>? in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: nil)
        }
    }

    private static func kind(of update: BrowserPageUpdate) -> Kind {
        switch update {
        case .page: .page
        case .pageSize: .pageSize
        case .cursor: .cursor
        case .textFocus: .textFocus
        case .clipboard: .clipboard
        }
    }
}
