import { env } from "../../../env";
import { hexclaveSyncDependencies } from "../../../../services/auth/hexclave/runtime";
import { handleStackWebhook } from "../../../../services/auth/stackWebhook";
import { withApiRouteSpan } from "../../../../services/telemetry";

/**
 * Hexclave (formerly Stack Auth) webhook receiver, delivered by Svix for every
 * event type. Authenticated only by the Svix signature over the raw body with
 * `STACK_WEBHOOK_SECRET`; no cookie or bearer is read. Each event reconciles
 * the Hexclave mirror from the server API, and removals revoke Cloud machine
 * access at once. See services/auth/stackWebhook.ts for the status contract.
 */
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
    }),
  );
}
