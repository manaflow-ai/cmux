import { Effect } from "effect";
import { changeAccountVisibility, parseAccountVisibility } from "../../../../../../services/coderouter/accountSharing";
import { teamPermissionRequired } from "../../../../../../services/coderouter/accountAdministration";
import { resolveCodeRouterRequestContext } from "../../../../../../services/coderouter/requestContext";
import { normalizeVmId } from "../../../../../../services/coderouter/teamMachines";
import { coderouterControlRoute } from "../../../../../../services/coderouter/requestTelemetry";
import { readJsonBody } from "../../../claude-upstream/route";

type AccountSharingDependencies = {
  readonly resolve: typeof resolveCodeRouterRequestContext;
  readonly change: typeof changeAccountVisibility;
};

/**
 * Shares an account with the team or makes it private. Either direction needs
 * account administration (accountAdministration.ts): sharing reaches every
 * member, and withdrawing a shared account takes it from them.
 */
export function makeAccountSharingHandler(dependencies: AccountSharingDependencies = {
  resolve: resolveCodeRouterRequestContext,
  change: changeAccountVisibility,
}) {
  return async (request: Request, context: { params: Promise<{ accountId: string }> }): Promise<Response> => {
    const resolved = await dependencies.resolve(request);
    if (!resolved.ok) return resolved.response;
    const accountId = normalizeVmId((await context.params).accountId);
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    const value = body.value as { visibility?: unknown; family?: unknown } | null;
    const visibility = parseAccountVisibility(value?.visibility);
    const family = value?.family;
    if (!accountId || !visibility || (family !== "native" && family !== "claude")) {
      return Response.json({ error: "invalid_request" }, { status: 400 });
    }
    if (!resolved.value.team.manageAccounts) {
      return teamPermissionRequired(resolved.value.team, visibility === "team" ? "share_account" : "change_shared_account");
    }
    const result = await Effect.runPromise(dependencies.change({
      accountId, family, visibility, teamId: resolved.value.team.teamId, userId: resolved.value.user.id,
    }).pipe(Effect.either));
    if (result._tag === "Left") return Response.json({ error: "account_store_unavailable" }, { status: 503 });
    if (!result.right) return Response.json({ error: "not_found" }, { status: 404 });
    return Response.json(result.right, { headers: { "cache-control": "no-store" } });
  };
}

export const PATCH = coderouterControlRoute("accounts", "/api/coderouter/accounts/[accountId]/sharing", makeAccountSharingHandler());
