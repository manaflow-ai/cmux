// Deferred best-effort work after a coderouter response. A leaf module with
// no coderouter imports: the PostHog sink (`analytics.ts`) and the ClickHouse
// ledger (`usageLedger.ts`) share it, and tests that replace `analytics.ts`
// with a partial mock must not break the ledger's import.
import { after } from "next/server";

/**
 * Runs a best-effort telemetry task after the response is sent. Shared by the
 * PostHog capture and the ClickHouse usage ledger so both leave the request
 * path the same way.
 */
export function deferCoderouterTask(task: Promise<unknown>): void {
  try {
    after(task);
  } catch {
    // Unit tests and non-request scripts do not have a Next request scope.
    // The promise is already running; always absorb rejection.
    void task.catch(() => undefined);
  }
}
