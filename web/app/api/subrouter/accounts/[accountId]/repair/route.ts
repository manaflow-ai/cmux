import { cloudDb } from "../../../../../../db/client";
import { readSubrouterAccountInput } from "../../../../../../services/subrouter/accountInput";
import { resolveSubrouterRequestContext } from "../../../../../../services/subrouter/requestContext";
import { subrouterErrorResponse } from "../../../../../../services/subrouter/routeHelpers";
import { getTenantForTeam } from "../../../../../../services/subrouter/tenants";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type RouteContext = {
  readonly params: Promise<{ readonly accountId: string }>;
};

export async function POST(
  request: Request,
  routeContext: RouteContext,
): Promise<Response> {
  const { accountId: rawAccountId } = await routeContext.params;
  const accountId = rawAccountId.trim();
  if (!accountId || accountId.length > 200) {
    return jsonResponse({ error: "invalid_request" }, 400);
  }

  const resolved = await resolveSubrouterRequestContext(request, {
    manageAccounts: true,
  });
  if (!resolved.ok) return resolved.response;
  const context = resolved.value;

  const input = await readSubrouterAccountInput(request);
  if (!input.ok) {
    return jsonResponse({ error: "invalid_request" }, input.status);
  }
  try {
    const tenant = await getTenantForTeam(
      cloudDb(),
      context.team.teamId,
      { tenantKeySecret: context.config.tenantKeySecret },
    );
    if (!tenant) return jsonResponse({ error: "account_not_found" }, 404);
    const account = await context.client.repairAccount(
      tenant.tenantKey,
      accountId,
      input.value,
    );
    return jsonResponse({ teamId: context.team.teamId, account });
  } catch (err) {
    return subrouterErrorResponse(err);
  }
}
