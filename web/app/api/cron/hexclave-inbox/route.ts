import { env } from "../../../env";
import { CRON_DRAIN_ENTITY_LIMIT, maintainHexclaveInbox } from "../../../../services/auth/hexclave/runtime";
import { authorizeCronRequest } from "../../../../services/cronAuth";
import { reportCronFailure, runMonitoredCron } from "../../../../services/observability/cronMonitor";

// One drain: up to CRON_DRAIN_ENTITY_LIMIT reconciles, each a few Hexclave
// reads with a 5 s timeout, and it stops at the first Hexclave throttle.
export const maxDuration = 60;

/**
 * Applies Hexclave webhook deliveries waiting in the inbox (see
 * services/auth/hexclave/inbox.ts). The webhook kicks a small drain after each
 * delivery; this every-minute run picks up whatever that left: throttled
 * events once their backoff ends, and bursts larger than one kick.
 */
export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) return Response.json({ error: "unauthorized" }, { status: 401 });
  return runMonitoredCron("hexclave-inbox", async () => {
    try {
      const result = await maintainHexclaveInbox({
        projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
        secretServerKey: env.STACK_SECRET_SERVER_KEY,
        entityLimit: CRON_DRAIN_ENTITY_LIMIT,
      });
      // Alert only when the stuck or dead-letter count changed, so a stable
      // backlog does not re-alert every minute.
      if (result.alert) {
        reportCronFailure(
          "hexclave-inbox",
          new Error(`Hexclave webhook inbox: ${result.stuck} stuck, ${result.deadLettered} dead-lettered`),
          { stuck: result.stuck, deadLettered: result.deadLettered },
          { stage: "stuck" },
        );
      }
      // A throttled drain is the inbox working as designed, not a failure.
      return Response.json({ ok: true, ...result });
    } catch (error) {
      reportCronFailure("hexclave-inbox", error);
      return Response.json({ error: "hexclave_inbox_failed" }, { status: 503 });
    }
  });
}
