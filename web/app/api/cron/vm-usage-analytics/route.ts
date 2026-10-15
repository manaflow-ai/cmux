import { authorizeCronRequest } from "../../../../services/cronAuth";
import { reportCronFailure, runMonitoredCron } from "../../../../services/observability/cronMonitor";
import { captureVmUsageHourly } from "../../../../services/vms/usageAnalytics";

export const maxDuration = 120;

/**
 * Hourly `cloud_vm_usage_hourly` events (services/vms/usageAnalytics.ts):
 * one per machine that ran during the previous whole UTC hour. A failed
 * delivery answers 503 so the Sentry monitor sees it; a rerun of the same
 * hour is idempotent through the events' natural insert ids.
 */
export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  return runMonitoredCron("vm-usage-analytics", async () => {
    try {
      const summary = await captureVmUsageHourly();
      const ok = summary.failed === 0;
      return Response.json({ ok, ...summary }, { status: ok ? 200 : 503 });
    } catch (err) {
      reportCronFailure("vm-usage-analytics", err);
      return Response.json({ error: "vm_usage_analytics_failed" }, { status: 500 });
    }
  });
}
