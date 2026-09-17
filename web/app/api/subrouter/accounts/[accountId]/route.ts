import {
  jsonResponse,
} from "../../../../../services/vms/routeHelpers";
import {
  normalizeAccountId,
  subrouterErrorResponse,
} from "../../../../../services/subrouter/routeHelpers";
import { resolveSubrouterRequestContext } from "../../../../../services/subrouter/requestContext";


type RouteContext = {
  params: Promise<{ accountId: string }>;
};

export async function DELETE(request: Request, context: RouteContext): Promise<Response> {
  const { accountId: rawAccountId } = await context.params;
  const accountId = normalizeAccountId(rawAccountId);
  if (!accountId) {
    return jsonResponse({ error: "invalid_request" }, 400);
  }

  const resolved = await resolveSubrouterRequestContext(request, {
    permission: "manage",
  });
  if (!resolved.ok) return resolved.response;
  const { team, accessToken, client } = resolved.value;

  try {
    const tenant = await client.exchangeTeam(accessToken, team);
    await client.deleteAccount(tenant.tenantKey, accountId);
    return jsonResponse({ ok: true, teamId: team.teamId });
  } catch (err) {
    return subrouterErrorResponse(err);
  }
}
