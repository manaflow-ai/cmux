// Deferred, rate-limited `last_used_at` writes for credentials that
// authenticate every request. The timestamp is display metadata, so a request
// never waits for it and each credential is written at most once per interval
// per process. The usage ledger stays per-request and is the billing record.

type Pending = { readonly teamId: string; readonly promise: Promise<void> };

export type LastUsedWriter = {
  /** Queues a write for after the current task; never throws or blocks. */
  readonly schedule: (id: string, teamId: string, now: Date) => void;
  /** Resolves when this process's queued writes for the team have settled. */
  readonly settled: (teamId: string) => Promise<void>;
};

export type LastUsedWriterOptions = {
  readonly intervalMs: number;
  /**
   * Persists `now` unless the stored value is newer than `staleBefore`.
   * Several web instances write the same row, so the write must never move the
   * timestamp backwards.
   */
  readonly write: (id: string, now: Date, staleBefore: Date) => Promise<unknown>;
  /** Called at most once per interval after a failed write. */
  readonly reportFailure: () => void;
  readonly cleanupThreshold?: number;
};

export function createLastUsedWriter(options: LastUsedWriterOptions): LastUsedWriter {
  const cleanupThreshold = options.cleanupThreshold ?? 2_048;
  const pending = new Map<string, Pending>();
  const lastWriteAt = new Map<string, number>();
  let lastFailureReportedAt = Number.NEGATIVE_INFINITY;

  function schedule(id: string, teamId: string, now: Date): void {
    if (pending.has(id)) return;
    const nowMs = now.getTime();
    const lastMs = lastWriteAt.get(id);
    if (lastMs !== undefined && nowMs - lastMs < options.intervalMs) return;

    // Credentials can belong to short-lived clients. Drop old entries so the
    // process does not retain every credential it has seen. Insertion order is
    // write order, so stale entries come first.
    if (lastWriteAt.size >= cleanupThreshold) {
      for (const [trackedId, trackedAt] of lastWriteAt) {
        if (nowMs - trackedAt < options.intervalMs) break;
        lastWriteAt.delete(trackedId);
      }
    }
    // Refresh insertion order so cleanup treats this as the newest entry.
    lastWriteAt.delete(id);
    lastWriteAt.set(id, nowMs);
    let resolve!: () => void;
    const promise = new Promise<void>((done) => { resolve = done; });
    pending.set(id, { teamId, promise });
    queueMicrotask(() => {
      void Promise.resolve()
        .then(() => options.write(id, now, new Date(nowMs - options.intervalMs)))
        .then(() => undefined)
        .catch(() => {
          // A failed best-effort write must not suppress the next retry for a
          // full interval.
          lastWriteAt.delete(id);
          const failedAt = Date.now();
          if (failedAt - lastFailureReportedAt >= options.intervalMs) {
            lastFailureReportedAt = failedAt;
            options.reportFailure();
          }
        })
        .finally(() => {
          resolve();
          pending.delete(id);
        });
    });
  }

  async function settled(teamId: string): Promise<void> {
    await Promise.all(
      [...pending.values()]
        .filter((entry) => entry.teamId === teamId)
        .map((entry) => entry.promise),
    );
  }

  return { schedule, settled };
}
