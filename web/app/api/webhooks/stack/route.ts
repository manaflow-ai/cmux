import { env } from "../../../env";
import { after } from "next/server";
import {
  drainHexclaveInboxNow,
  hexclaveInboxStore,
  hexclaveSyncDependencies,
  WEBHOOK_KICK_ENTITY_LIMIT,
} from "../../../../services/auth/hexclave/runtime";
import { handleStackWebhook } from "../../../../services/auth/stackWebhook";
import { withApiRouteSpan } from "../../../../services/telemetry";

/**
 * Hexclave (formerly Stack Auth) webhook receiver, delivered by Svix for every
 * event type. Authenticated only by the Svix signature over the raw body with
 * `STACK_WEBHOOK_SECRET`; no cookie or bearer is read. Each event reconciles
 * the Hexclave mirror from the server API, and removals revoke Cloud machine
 * access at once. See services/auth/stackWebhook.ts for the status contract.
 */
// Verify, store, answer; the after-response drain is bounded to
// WEBHOOK_KICK_ENTITY_LIMIT reconciles and stops at a Hexclave throttle.
export const maxDuration = 60;

export async function POST(request: Request): Promise<Response> {
  return withApiRouteSpan(
    request,
    "/api/webhooks/stack",
    { "cmux.subsystem": "auth", "cmux.auth.operation": "stack_webhook" },
    () => handleStackWebhook(request, {
      webhookSecret: () => env.STACK_WEBHOOK_SECRET,
      sync: () => hexclaveSyncDependencies({
        projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
        secretServerKey: env.STACK_SECRET_SERVER_KEY,
      }),
      inbox: hexclaveInboxStore,
      // Apply what is waiting right after answering; the every-minute cron
      // drains whatever this kick leaves (throttled, or more than its limit).
      scheduleDrain: () => after(async () => {
        try {
          await drainHexclaveInboxNow({
            projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
            secretServerKey: env.STACK_SECRET_SERVER_KEY,
            entityLimit: WEBHOOK_KICK_ENTITY_LIMIT,
          });
        } catch (error) {
          console.error("stack_webhook_inbox_kick_failed", { errorType: error instanceof Error ? error.name : typeof error });
        }
      }),
    }),
  );
}
