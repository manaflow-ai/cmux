import { authorizeCronRequest } from "../../../../services/cronAuth";
import { reportCronFailure, runMonitoredCron } from "../../../../services/observability/cronMonitor";
import { runVmMetering, vmMeteringEnabled } from "../../../../services/vms/metering/vmMeterJob";
import { postgresVmMeteringDependencies } from "../../../../services/vms/metering/vmMeterPostgres";

// The provider reads (8 at a time, 10 s each) for every open interval.
export const maxDuration = 300;

/**
 * Cloud VM metering (services/vms/metering, plans/cmux-next/cloud-metering-DESIGN.md):
 * copies Postgres runtime intervals to ClickHouse and reconciles them against
 * the provider every 5 minutes. Off unless CMUX_VM_METERING_CLICKHOUSE=1.
 */
export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  if (!vmMeteringEnabled(process.env)) return Response.json({ ok: true, enabled: false });
  return runMonitoredCron("vm-metering", async () => {
    try {
      const result = await runVmMetering(postgresVmMeteringDependencies());
      const ok = !result.enabled || !result.insertFailed;
      if (!ok) reportCronFailure("vm-metering", new Error("ClickHouse metering insert failed"), { ...result }, { stage: "partial", level: "warning" });
      return Response.json({ ok, ...result }, { status: ok ? 200 : 503 });
    } catch (err) {
      reportCronFailure("vm-metering", err);
      return Response.json({ error: "vm_metering_failed" }, { status: 500 });
    }
  });
}
