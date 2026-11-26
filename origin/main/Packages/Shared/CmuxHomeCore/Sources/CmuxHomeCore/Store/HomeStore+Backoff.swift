import Foundation

// HomeStore's resend backoff: delayed resends and upload passes for sends
// that got no answer, and giving up when the delays run out.
extension HomeStore {
    // MARK: Backoff

    enum BackoffAction { case resend, upload }

    /// Runs `action` for `key` after its next `resendBackoff` delay on the
    /// store's clock, if still online then (a reconnect resends it
    /// anyway). False when the delays ran out.
    func scheduleBackoff(_ key: IdempotencyKey, _ action: BackoffAction) -> Bool {
        let attempt = backoffAttempts[key, default: 0]
        guard attempt < Self.resendBackoff.count else { return false }
        backoffAttempts[key] = attempt + 1
        let delay = Self.resendBackoff[attempt]
        let clock = self.clock
        backoffTasks[key]?.cancel()
        backoffTasks[key] = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            // A newer backoff replaced this one while it woke: leave its handle.
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.backoffTasks[key] = nil
            guard self.isOnline else { return }
            switch action {
            case .resend:
                if let intent = self.log.takeResend(key) { self.enqueueResends([intent]) }
            case .upload:
                if self.uploads[key]?.waitingForReconnect == true { self.resumeUpload(key) }
            }
        }
        return true
    }

    /// The resends ran out: a send fails "Not Delivered" with the last
    /// answer (`retry` sends it again under the same key) and leaves the
    /// queue; another op is dropped and reported through `onUnanswered`.
    /// `reachedOwner`: the send itself went to the owner (not only its
    /// uploads), so the owner may have committed it
    /// (`TranscriptItem.mayHaveBeenDelivered`).
    func giveUp(_ key: IdempotencyKey, _ rejection: HomeRejection, reachedOwner: Bool) {
        cancelBackoff(key)
        guard let entry = log.entries.first(where: { $0.intent.key == key }) else { return }
        if case .sendMessage = entry.intent.op {
            log.setUploading(key, false)
            log.fail(key, rejection, mayHaveBeenDelivered: reachedOwner)
        } else {
            log.discard(key)
        }
        uploads[key]?.waitingForReconnect = false
        leaveSendQueue(key)
        afterLogChange(entry.intent.op)
        if case .sendMessage = entry.intent.op {} else { reportUnanswered(entry.intent) }
    }

    func cancelBackoff(_ key: IdempotencyKey) {
        backoffTasks.removeValue(forKey: key)?.cancel()
        backoffAttempts[key] = nil
    }

    /// Pending delays stop (a disconnect: the reconnect resends; `stop`).
    func cancelBackoffs() {
        for task in backoffTasks.values { task.cancel() }
        backoffTasks.removeAll()
    }
}
