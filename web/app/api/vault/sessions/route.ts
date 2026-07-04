import { cloudDb } from "../../../../db/client";
import { isVaultConfigured } from "../../../../services/vault/config";
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
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  if (!isVaultConfigured()) return jsonResponse({ error: "vault_not_configured" }, 503);
  const user = await verifyRequest(request);
  if (!user) return unauthorized();

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

  const page = await queryVaultSessionListPage(cloudDb(), {
    userId: user.id,
    agent,
    agentSessionId: agentSessionIdValue,
    q: url.searchParams.get("q") ?? undefined,
    cursor: url.searchParams.get("cursor"),
    limit,
  });

  return jsonResponse(serializeVaultSessionListPage(page));
}
