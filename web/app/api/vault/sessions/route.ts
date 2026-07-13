import { cloudDb } from "../../../../db/client";
import {
  normalizeAgent,
  normalizeAgentSessionId,
  type VaultAgent,
} from "../../../../services/vault/validation";
import {
  normalizeVaultSessionListLimit,
  queryVaultSessionListPage,
  serializeVaultSessionListPage,
} from "../../../../services/vault/sessionList";
import { withAuthedVaultApiRoute } from "../../../../services/vault/routeHelpers";
import { setSpanAttributes } from "../../../../services/telemetry";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  return withAuthedVaultApiRoute(
    request,
    "/api/vault/sessions",
    { "cmux.vault.operation": "sessions.list" },
    "/api/vault/sessions GET failed",
    {},
    async ({ user, span }) => {
      const url = new URL(request.url);
      const limit = normalizeVaultSessionListLimit(url.searchParams.get("limit"));

      const agentParam = url.searchParams.get("agent");
      let agent: VaultAgent | undefined;
      if (agentParam) {
        const parsedAgent = normalizeAgent(agentParam);
        if (!parsedAgent.ok) return jsonResponse({ error: parsedAgent.error }, 400);
        agent = parsedAgent.value;
      }

      const agentSessionIdParam = url.searchParams.get("agentSessionId");
      let agentSessionIdValue: string | undefined;
      if (agentSessionIdParam) {
        const agentSessionId = normalizeAgentSessionId(agentSessionIdParam);
        if (!agentSessionId.ok) return jsonResponse({ error: agentSessionId.error }, 400);
        agentSessionIdValue = agentSessionId.value;
      }

      const q = url.searchParams.get("q") ?? undefined;
      setSpanAttributes(span, {
        "cmux.vault.limit": limit,
        "cmux.vault.agent_filter": agent,
        "cmux.vault.agent_session_id_filter_set": Boolean(agentSessionIdValue),
        "cmux.vault.search_set": Boolean(q),
        "cmux.vault.cursor_set": Boolean(url.searchParams.get("cursor")),
      });

      const page = await queryVaultSessionListPage(cloudDb(), {
        userId: user.id,
        agent,
        agentSessionId: agentSessionIdValue,
        q,
        cursor: url.searchParams.get("cursor"),
        limit,
      });
      const serialized = serializeVaultSessionListPage(page);
      setSpanAttributes(span, {
        "cmux.vault.result_count": serialized.sessions.length,
        "cmux.vault.has_more": Boolean(serialized.nextCursor),
      });

      return jsonResponse(serialized);
    },
  );
}
