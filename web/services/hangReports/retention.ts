import * as Effect from "effect/Effect";

import { HangReportsRepository } from "./repository";

/** Hang reports are kept for 90 days after receipt. */
export const HANG_REPORT_RETENTION_DAYS = 90;
export const RETENTION_BATCH_SIZE = 1_000;
/** One run deletes at most this many batches; the next daily run continues. */
export const RETENTION_MAX_BATCHES = 50;

export type RetentionResult = {
  readonly deleted: number;
  /** False when the run stopped at the batch limit with old rows left. */
  readonly complete: boolean;
};

/** Delete rows received more than 90 days before `now`, in bounded batches. */
export function pruneExpiredHangReports(now: Date) {
  return Effect.gen(function* () {
    const repository = yield* HangReportsRepository;
    const cutoff = new Date(now.getTime() - HANG_REPORT_RETENTION_DAYS * 86_400_000);
    let deleted = 0;
    for (let batch = 0; batch < RETENTION_MAX_BATCHES; batch += 1) {
      const removed = yield* repository.deleteReceivedBefore(cutoff, RETENTION_BATCH_SIZE);
      deleted += removed;
      if (removed < RETENTION_BATCH_SIZE) return { deleted, complete: true } satisfies RetentionResult;
    }
    return { deleted, complete: false } satisfies RetentionResult;
  }).pipe(Effect.withSpan("hang_reports.retention"));
}
