import {
  jsonResponse,
} from "../../../../services/vms/routeHelpers";
import { readSubrouterAccountInput } from "../../../../services/subrouter/accountInput";
import {
  subrouterErrorResponse,
} from "../../../../services/subrouter/routeHelpers";
import { resolveSubrouterRequestContext } from "../../../../services/subrouter/requestContext";
import { captureCoderouterEvent } from "../../../../services/coderouter/analytics";
import { mirrorConnectedAccount } from "../../../../services/coderouter/accountMirror";


export async function GET(request: Request): Promise<Response> {
  const resolved = await resolveSubrouterRequestContext(request, {
    permission: "use-or-manage",
  });
  if (!resolved.ok) return resolved.response;
  const context = resolved.value;

  try {
    const tenant = await context.client.exchangeTeam(context.accessToken, context.team);
    const accounts = await context.client.listAccounts(tenant.tenantKey);
    captureCoderouterEvent({
      event: "coderouter_account_status_viewed",
      teamId: context.team.teamId,
      properties: {
        source: "legacy_dashboard",
        account_count: accounts.length,
        account_error_count: 0,
      },
    });
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
    // Connect once, every machine works: a Claude account connected here is
    // mirrored into the coderouter vault that cloud machines route through.
    const vmPlane = await mirrorConnectedAccount({
      teamId: context.team.teamId,
      stackUserId: context.user.id,
      input: input.value,
      created: account,
    });
    captureCoderouterEvent({
      event: "coderouter_account_added",
      userId: context.user.id,
      teamId: context.team.teamId,
      properties: {
        provider: input.value.provider,
        source: "legacy_dashboard",
        already_exists: false,
      },
    });
    return jsonResponse({ teamId: context.team.teamId, account, vmPlane });
  } catch (err) {
    return subrouterErrorResponse(err);
  }
}
