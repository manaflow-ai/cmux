import { authorizeCronRequest } from "../../../../services/cronAuth";
import { reportCronFailure, runMonitoredCron } from "../../../../services/observability/cronMonitor";
import { releasePausedAddresses } from "../../../../services/vms/addressReleaseJob";
import { enforceVmIdlePause } from "../../../../services/vms/idlePauseJob";
import { runVmWorkflow } from "../../../../services/vms/workflows";

// Up to 500 probes at 8 at a time, each bounded at 25 s, plus the pauses.
export const maxDuration = 300;

/** Idle auto-pause (services/vms/idlePause.ts): every 5 minutes. */
export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) return Response.json({ error: "unauthorized" }, { status: 401 });
  return runMonitoredCron("vm-idle-pause", async () => {
    try {
      const result = await runVmWorkflow(enforceVmIdlePause());
      console.info("[VM] cron idle pause", JSON.stringify(result));
      // Paused machines past CMUX_VM_PAUSED_ADDRESS_RELEASE_HOURS give their
      // private address back (services/vms/addressRelease.ts); off by default.
      const addressRelease = await runVmWorkflow(releasePausedAddresses()).catch((error: unknown) => {
        reportCronFailure("vm-idle-pause", error, {}, { stage: "address_release", level: "warning" });
        return null;
      });
      if (addressRelease?.enabled) console.info("[VM] cron address release", JSON.stringify(addressRelease));
      if (result.errors > 0) {
        reportCronFailure(
          "vm-idle-pause",
          new Error(`Idle pause failed for ${result.errors} of ${result.checked} machines`),
          { ...result },
          { stage: "partial", level: "warning" },
        );
      }
      return Response.json({ ok: true, ...result, ...(addressRelease?.enabled ? { addressRelease } : {}) });
    } catch (error) {
      reportCronFailure("vm-idle-pause", error);
      return Response.json({ error: "vm_idle_pause_failed" }, { status: 503 });
    }
  });
}
