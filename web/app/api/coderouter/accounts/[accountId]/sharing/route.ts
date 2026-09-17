import { Effect } from "effect";
import { changeAccountVisibility, parseAccountVisibility } from "../../../../../../services/coderouter/accountSharing";
import { resolveCodeRouterRequestContext } from "../../../../../../services/coderouter/requestContext";
import { normalizeVmId } from "../../../../../../services/coderouter/teamMachines";
import { coderouterControlRoute } from "../../../../../../services/coderouter/requestTelemetry";
import { readJsonBody } from "../../../claude-upstream/route";

export const PATCH = coderouterControlRoute("accounts", "/api/coderouter/accounts/[accountId]/sharing", async (
  request: Request, context: { params: Promise<{ accountId: string }> },
) => {
  const resolved = await resolveCodeRouterRequestContext(request);
  if (!resolved.ok) return resolved.response;
  if (!resolved.value.team.manageAccounts) return Response.json({ error: "forbidden" }, { status: 403 });
  const accountId = normalizeVmId((await context.params).accountId);
  const body = await readJsonBody(request);
  if (!body.ok) return body.response;
  const value = body.value as { visibility?: unknown; family?: unknown } | null;
  const visibility = parseAccountVisibility(value?.visibility);
  const family = value?.family;
  if (!accountId || !visibility || (family !== "native" && family !== "claude")) {
    return Response.json({ error: "invalid_request" }, { status: 400 });
  }
  const result = await Effect.runPromise(changeAccountVisibility({
    accountId, family, visibility, teamId: resolved.value.team.teamId, userId: resolved.value.user.id,
  }).pipe(Effect.either));
  if (result._tag === "Left") return Response.json({ error: "account_store_unavailable" }, { status: 503 });
  if (!result.right) return Response.json({ error: "not_found" }, { status: 404 });
  return Response.json(result.right, { headers: { "cache-control": "no-store" } });
});
