import { removeAccount } from "../../../../../services/coderouter/accounts";
import { resolveCodeRouterRequestContext } from "../../../../../services/coderouter/requestContext";
import { captureCoderouterEvent } from "../../../../../services/coderouter/analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "../../../../../services/coderouter/observability";


const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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
    const resolved = await dependencies.resolve(request);
    if (!resolved.ok) return resolved.response;
    const { accountId } = await context.params;
    if (!UUID.test(accountId)) {
      return Response.json({ error: "invalid_request" }, { status: 400 });
    }
    let result;
    try {
      result = await dependencies.remove({
        teamId: resolved.value.team.teamId,
        accountId,
      });
    } catch (error) {
      reportCoderouterFailure("rds", error, { operation: "remove_account" });
      return Response.json(
        {
          error: "account_remove_unavailable",
          message:
            "coderouter could not remove this account. Nothing was partially removed; retry shortly.",
          retryable: true,
        },
        {
          status: 503,
          headers: { "cache-control": "no-store", "retry-after": "5" },
        },
      );
    }
    if (!result.removed) {
      return Response.json(
        {
          error: "not_found",
          message:
            "That coderouter account no longer exists. Refresh with `cr` and retry if needed.",
          retryable: false,
        },
        { status: 404 },
      );
    }
    captureCoderouterEvent({
      event: "coderouter_account_removed",
      userId: resolved.value.user.id,
      teamId: resolved.value.team.teamId,
      properties: {
        source: "native_api",
        last_account: result.lastAccount,
        legacy_cleanup_pending: result.legacyCleanupPending,
      },
    });
    addCoderouterBreadcrumb("account", "Provider account removed", {
      last_account: result.lastAccount,
      legacy_cleanup_pending: result.legacyCleanupPending,
    });
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
