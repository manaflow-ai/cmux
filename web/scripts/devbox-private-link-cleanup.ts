// Maintainer-only image verification support; never imported by app/API routes.
import { Effect, Schedule } from "effect";
import { FreestyleApiError } from "freestyle";
import { ProviderError } from "../services/vms/drivers/types";

/** A provider conflict means deletion is blocked by an attachment still in use. */
function isDeletionConflict(error: unknown): boolean {
  const cause = error instanceof ProviderError ? error.cause : error;
  return cause instanceof FreestyleApiError && cause.status === 409;
}

/**
 * Only a successful provider delete confirms completion. The SDK exposes no
 * detach-completion event, so retry explicit conflict responses with bounded
 * exponential backoff. Auth/config failures fail immediately. An overall
 * deadline also bounds an unresponsive request, including within scope cleanup.
 * Errors retain only our resource label, never an upstream payload or credential.
 */
export function cleanupPrivateLinkResource(label: string, run: (signal: AbortSignal) => Promise<void>) {
  return Effect.tryPromise({ try: run, catch: (error) => error }).pipe(
    Effect.retry({
      while: isDeletionConflict,
      schedule: Schedule.intersect(Schedule.exponential("100 millis"), Schedule.recurs(7)),
    }),
    Effect.interruptible,
    Effect.timeoutFail({ duration: "30 seconds", onTimeout: () => new Error("Cleanup deadline exceeded") }),
    Effect.mapError(() => new Error(`Cleanup failed: ${label}`)),
    Effect.orDie,
  );
}
