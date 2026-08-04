import {
  jsonResponse,
} from "../../../../services/vms/routeHelpers";
import { readSubrouterAccountInput } from "../../../../services/subrouter/accountInput";
import {
  subrouterErrorResponse,
} from "../../../../services/subrouter/routeHelpers";
import { resolveSubrouterRequestContext } from "../../../../services/subrouter/requestContext";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  const resolved = await resolveSubrouterRequestContext(request, {
    permission: "use-or-manage",
  });
  if (!resolved.ok) return resolved.response;
  const context = resolved.value;

  try {
    const tenant = await context.client.exchangeTeam(context.accessToken, context.team);
    const accounts = await context.client.listAccounts(tenant.tenantKey);
    return jsonResponse({ teamId: context.team.teamId, accounts });
  } catch (err) {
    return subrouterErrorResponse(err);
  }
}

export async function POST(request: Request): Promise<Response> {
  const resolved = await resolveSubrouterRequestContext(request, {
    permission: "manage",
  });
  if (!resolved.ok) return resolved.response;
  const context = resolved.value;

  const input = await readSubrouterAccountInput(request);
  if (!input.ok) {
    return jsonResponse({ error: "invalid_request" }, input.status);
  }
  try {
    const tenant = await context.client.exchangeTeam(context.accessToken, context.team);
    const account = await context.client.createAccount(
      tenant.tenantKey,
      input.value,
    );
    return jsonResponse({ teamId: context.team.teamId, account });
  } catch (err) {
    return subrouterErrorResponse(err);
  }
}
