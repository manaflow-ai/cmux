import { authorizeCronRequest } from "../../../../services/cronAuth";
import { reportCronFailure, runMonitoredCron } from "../../../../services/observability/cronMonitor";
import { enforceGoRuntimeLimits } from "../../../../services/vms/goRuntimeLimits";
import { runVmWorkflow } from "../../../../services/vms/workflows";
import { env } from "../../../env";
import { STUCK_ATTEMPTS } from "../../../../services/auth/hexclave/inbox";
import { CRON_DRAIN_ENTITY_LIMIT, drainHexclaveInboxNow } from "../../../../services/auth/hexclave/runtime";

export const maxDuration = 60;

export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) return Response.json({ error: "unauthorized" }, { status: 401 });
  return runMonitoredCron("vm-runtime-limits", async () => {
    // The Hexclave webhook inbox rides on this every-minute cron. Its own
    // failures are reported and never change this cron's answer.
    const hexclaveInbox = await drainHexclaveWebhookInbox();
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
      return Response.json({ ok: result.errors === 0, ...result, hexclaveInbox }, { status: result.errors ? 503 : 200 });
    } catch (error) {
      reportCronFailure("vm-runtime-limits", error);
      return Response.json({ error: "vm_runtime_limits_failed" }, { status: 503 });
    }
  });
}

async function drainHexclaveWebhookInbox() {
  try {
    const result = await drainHexclaveInboxNow({
      projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
      secretServerKey: env.STACK_SECRET_SERVER_KEY,
      entityLimit: CRON_DRAIN_ENTITY_LIMIT,
    });
    if (result.stuck > 0) {
      reportCronFailure(
        "vm-runtime-limits",
        new Error(`${result.stuck} Hexclave webhook events failed ${STUCK_ATTEMPTS} or more times`),
        { stuck: result.stuck },
        { stage: "hexclave_inbox_stuck", level: "warning" },
      );
    }
    return result;
  } catch (error) {
    reportCronFailure("vm-runtime-limits", error, {}, { stage: "hexclave_inbox", level: "warning" });
    return { error: "hexclave_inbox_drain_failed" };
  }
}
