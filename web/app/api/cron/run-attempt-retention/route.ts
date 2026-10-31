import { authorizeCronRequest } from "../../../../services/cronAuth";
import { reportCronFailure, runMonitoredCron } from "../../../../services/observability/cronMonitor";
import { reapExpiredCloudVmAttempts } from "../../../../services/runs/dogfood";

// A batch of 20 provider destroys runs well under this budget; the cap only
// guards a hung provider call.
export const maxDuration = 60;

/**
 * Destroy a finished Run attempt's cloud VM once its terminal attach window
 * (`run_attempts.terminal_retain_until`) has passed. `scheduleAttemptRetention`
 * keeps the VM attachable for that window; this is the reaper it relies on.
 */
export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  return runMonitoredCron("run-attempt-retention", async () => {
    try {
      const result = await reapExpiredCloudVmAttempts({ limit: 20 });
      return Response.json({ ok: result.errors === 0, ...result }, { status: result.errors === 0 ? 200 : 503 });
    } catch (err) {
      reportCronFailure("run-attempt-retention", err);
      return Response.json({ error: "run_attempt_retention_failed" }, { status: 503 });
    }
  });
}
