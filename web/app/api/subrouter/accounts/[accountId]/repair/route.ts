import { readSubrouterAccountInput } from "../../../../../../services/subrouter/accountInput";
import { resolveSubrouterRequestContext } from "../../../../../../services/subrouter/requestContext";
import {
  normalizeAccountId,
  subrouterErrorResponse,
} from "../../../../../../services/subrouter/routeHelpers";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";
import { captureCoderouterEvent } from "../../../../../../services/coderouter/analytics";


type RouteContext = {
  readonly params: Promise<{ readonly accountId: string }>;
};

export async function POST(
  request: Request,
  routeContext: RouteContext,
): Promise<Response> {
  const { accountId: rawAccountId } = await routeContext.params;
  const accountId = normalizeAccountId(rawAccountId);
  if (!accountId) {
    return jsonResponse({ error: "invalid_request" }, 400);
  }

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
    const account = await context.client.repairAccount(
      tenant.tenantKey,
      accountId,
      input.value,
    );
    captureCoderouterEvent({
      event: "coderouter_account_added",
      userId: context.user.id,
      teamId: context.team.teamId,
      properties: {
        provider: input.value.provider,
        source: "legacy_dashboard",
        already_exists: true,
      },
    });
    return jsonResponse({ teamId: context.team.teamId, account });
  } catch (err) {
    return subrouterErrorResponse(err);
  }
}
