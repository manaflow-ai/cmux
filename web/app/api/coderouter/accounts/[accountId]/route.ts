import { coderouterControlRoute } from "@/services/coderouter/requestTelemetry";
import { removeAccount } from "../../../../../services/coderouter/accounts";
import { removeClaudeAccount } from "../../../../../services/coderouter/claudeUpstream";
import {
  isTeamAccountId,
  removeTeamAccount,
  type TeamAccountRemoval,
} from "../../../../../services/coderouter/teamAccounts";
import { vaultAccessFromStackHeaders } from "../../../../../services/coderouter/vaultAccess";
import { normalizeAccountId } from "../../../../../services/subrouter/routeHelpers";
import { resolveCodeRouterRequestContext } from "../../../../../services/coderouter/requestContext";
import { captureCoderouterEvent } from "../../../../../services/coderouter/analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "../../../../../services/coderouter/observability";


export function createDeleteAccountHandler(dependencies: {
  readonly resolve: typeof resolveCodeRouterRequestContext;
  readonly remove: (input: {
    readonly teamId: string;
    readonly accountId: string;
    readonly request: Request;
  }) => Promise<TeamAccountRemoval>;
}) {
  return async (
    request: Request,
    context: { params: Promise<{ accountId: string }> },
  ): Promise<Response> => {
    const resolved = await dependencies.resolve(request);
    if (!resolved.ok) return resolved.response;
    const { accountId: rawAccountId } = await context.params;
    const accountId = normalizeAccountId(rawAccountId);
    if (!accountId || !isTeamAccountId(accountId)) {
      return Response.json({ error: "invalid_request" }, { status: 400 });
    }
    let result;
    try {
      result = await dependencies.remove({
        teamId: resolved.value.team.teamId,
        accountId,
        request,
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
        account_source: result.source,
        last_account: result.lastAccount,
        legacy_cleanup_pending: result.legacyCleanupPending,
      },
    });
    addCoderouterBreadcrumb("account", "Provider account removed", {
      account_source: result.source,
      last_account: result.lastAccount,
      legacy_cleanup_pending: result.legacyCleanupPending,
    });
    return Response.json(result, {
      headers: { "cache-control": "no-store" },
    });
  };
}

export const DELETE = coderouterControlRoute("accounts", "/api/coderouter/accounts/[accountId]", createDeleteAccountHandler({
  resolve: resolveCodeRouterRequestContext,
  // One removal path for every store, so a client that read one account list
  // does not have to know which store answered for each row.
  remove: async ({ teamId, accountId, request }) =>
    await removeTeamAccount({
      teamId,
      accountId,
      vault: await vaultAccessFromStackHeaders(request, teamId),
      removeNative: removeAccount,
      removeClaude: removeClaudeAccount,
    }),
}));
