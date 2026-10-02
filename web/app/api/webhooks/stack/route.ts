import { env } from "../../../env";
import { handleStackWebhook } from "../../../../services/auth/stackWebhook";
import { withApiRouteSpan } from "../../../../services/telemetry";
import { revokeTeamAccess, revokeTeamMemberAccess } from "../../../../services/vms/teamMemberRevocation";

/**
 * Stack Auth webhook receiver (delivered by Svix). Authenticated only by the
 * Svix signature over the raw body with `STACK_WEBHOOK_SECRET`; no cookie or
 * bearer is read. Removing a member revokes their access to that team's Cloud
 * machines at once. See services/auth/stackWebhook.ts for the status contract.
 */
export async function POST(request: Request): Promise<Response> {
  return withApiRouteSpan(
    request,
    "/api/webhooks/stack",
    { "cmux.subsystem": "auth", "cmux.auth.operation": "stack_webhook" },
    () => handleStackWebhook(request, {
      webhookSecret: () => env.STACK_WEBHOOK_SECRET,
      revokeTeamMemberAccess,
      revokeTeamAccess,
    }),
  );
}
