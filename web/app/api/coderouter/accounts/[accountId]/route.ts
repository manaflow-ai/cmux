import { removeAccount } from "../../../../../services/coderouter/accounts";
import { resolveCodeRouterRequestContext } from "../../../../../services/coderouter/requestContext";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function createDeleteAccountHandler(dependencies: {
  readonly resolve: typeof resolveCodeRouterRequestContext;
  readonly remove: (input: {
    readonly teamId: string;
    readonly accountId: string;
  }) => ReturnType<typeof removeAccount>;
}) {
  return async (
    request: Request,
    context: { params: Promise<{ accountId: string }> },
  ): Promise<Response> => {
    const resolved = await dependencies.resolve(request, "manage");
    if (!resolved.ok) return resolved.response;
    const { accountId } = await context.params;
    if (!UUID.test(accountId)) {
      return Response.json({ error: "invalid_request" }, { status: 400 });
    }
    const result = await dependencies.remove({
      teamId: resolved.value.team.teamId,
      accountId,
    });
    if (!result.removed) {
      return Response.json({ error: "not_found" }, { status: 404 });
    }
    return Response.json(result, {
      headers: { "cache-control": "no-store" },
    });
  };
}

export const DELETE = createDeleteAccountHandler({
  resolve: resolveCodeRouterRequestContext,
  remove: async ({ teamId, accountId }) =>
    await removeAccount(teamId, accountId),
});
