import { authorizeCronRequest } from "../../../../services/cronAuth";
import { reportCronFailure, runMonitoredCron } from "../../../../services/observability/cronMonitor";
import { enforceGoRuntimeLimits } from "../../../../services/vms/goRuntimeLimits";
import { runVmWorkflow } from "../../../../services/vms/workflows";

export const maxDuration = 60;

export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) return Response.json({ error: "unauthorized" }, { status: 401 });
  return runMonitoredCron("vm-runtime-limits", async () => {
    try {
      const result = await runVmWorkflow(enforceGoRuntimeLimits());
      if (result.errors > 0) {
        // Per-machine causes are logged by the job; this groups the run.
        reportCronFailure(
          "vm-runtime-limits",
          new Error(`Go runtime limit enforcement failed for ${result.errors} of ${result.checked} machines`),
          { checked: result.checked, paused: result.paused, errors: result.errors },
          { stage: "partial" },
        );
      }
      return Response.json({ ok: result.errors === 0, ...result }, { status: result.errors ? 503 : 200 });
    } catch (error) {
      reportCronFailure("vm-runtime-limits", error);
      return Response.json({ error: "vm_runtime_limits_failed" }, { status: 503 });
    }
  });
}
