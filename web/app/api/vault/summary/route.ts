import { cloudDb } from "@/db/client";
import { withAuthedVaultApiRoute } from "@/services/vault/routeHelpers";
import { queryVaultAgentSummary, summarizeVaultAgents } from "@/services/vault/summary";
import { setSpanAttributes } from "@/services/telemetry";
import { jsonResponse } from "@/services/vms/routeHelpers";

/** Totals for the Vault overview. 404 while the Vault release flag is off. */
export async function GET(request: Request): Promise<Response> {
  return withAuthedVaultApiRoute(
    request,
    "/api/vault/summary",
    { "cmux.vault.operation": "summary" },
    "/api/vault/summary GET failed",
    {},
    async ({ user, span }) => {
      const summary = summarizeVaultAgents(await queryVaultAgentSummary(cloudDb(), user.id));
      setSpanAttributes(span, { "cmux.vault.result_count": summary.sessionCount });
      return jsonResponse(summary, 200, { "cache-control": "private, no-store" });
    },
  );
}
