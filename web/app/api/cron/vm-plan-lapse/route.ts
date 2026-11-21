import { authorizeCronRequest } from "../../../../services/cronAuth";
import { reportCronFailure, runMonitoredCron } from "../../../../services/observability/cronMonitor";
import { enforceVmPlanLapse } from "../../../../services/vms/planLapseJob";
import { runVmWorkflow } from "../../../../services/vms/workflows";

export const maxDuration = 300;

/** Pause running machines of owners who no longer pay (services/vms/planLapseJob.ts): hourly. */
export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) return Response.json({ error: "unauthorized" }, { status: 401 });
  return runMonitoredCron("vm-plan-lapse", async () => {
    try {
      const { lapsed, ...summary } = await runVmWorkflow(enforceVmPlanLapse());
      const result = { ...summary, lapsedMachines: lapsed.length, lapsedOwners: new Set(lapsed.map((vm) => vm.userId)).size };
      console.info("[VM] cron plan lapse", JSON.stringify(result));
      if (result.errors > 0 || result.lookupErrors > 0 || result.outOfTime > 0 || result.tripped) {
        reportCronFailure(
          "vm-plan-lapse",
          new Error(`Plan lapse: ${result.errors} pause failures, ${result.lookupErrors} owner lookup failures, ${result.outOfTime} machines out of time, tripped=${result.tripped}`),
          { ...result },
          { stage: "partial", level: "warning" },
        );
      }
      return Response.json({ ok: true, ...result });
    } catch (error) {
      reportCronFailure("vm-plan-lapse", error);
      return Response.json({ error: "vm_plan_lapse_failed" }, { status: 503 });
    }
  });
}
