import { Effect, Schedule } from "effect";

const cleanupRetry = Schedule.intersect(Schedule.spaced("500 millis"), Schedule.recurs(20));

/** Delete a probe-owned resource, failing the verifier if cleanup is exhausted. */
export function cleanupPrivateLinkResource(label: string, run: (signal: AbortSignal) => Promise<void>) {
  return Effect.tryPromise({ try: run, catch: () => new Error(`Cleanup failed: ${label}`) }).pipe(
    Effect.retry(cleanupRetry),
    Effect.orDie,
  );
}
