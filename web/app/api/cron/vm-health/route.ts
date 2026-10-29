import { authorizeCronRequest } from "../../../../services/cronAuth";
import { reportCronFailure, runMonitoredCron } from "../../../../services/observability/cronMonitor";
import { deliverVmHealthAlert } from "../../../../services/observability/vmHealthAlerts";
import { handleVmHealthCron } from "../../../../services/vms/health/cron";
import { sweepVmHealth } from "../../../../services/vms/health/sweep";
import { runVmWorkflow } from "../../../../services/vms/workflows";

// The sweep stops starting probes at its own budget (VM_HEALTH_DEFAULT_BUDGET_MS,
// or the capped CMUX_VM_HEALTH_BUDGET_MS override in services/vms/health/cron.ts);
// this cap only guards a provider call that ignores its abort signal.
export const maxDuration = 300;

export async function GET(request: Request): Promise<Response> {
  // Unauthenticated hits never reach the sweep or the cron monitor.
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  return runMonitoredCron("vm-health", async () => {
    try {
      return await handleVmHealthCron(request, {
        sweep: (options) => runVmWorkflow(sweepVmHealth(options)),
        alert: (report, pageUrl) => deliverVmHealthAlert(report, { pageUrl }),
        env: process.env,
      });
    } catch (err) {
      reportCronFailure("vm-health", err);
      return Response.json({ error: "vm_health_failed" }, { status: 500 });
    }
  });
}
