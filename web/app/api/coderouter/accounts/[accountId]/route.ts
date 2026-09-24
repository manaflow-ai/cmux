import { coderouterControlRoute } from "@/services/coderouter/requestTelemetry";
// One provider account: remove it (DELETE). A member removes their own private
// accounts; a shared account needs account administration
// (accountAdministration.ts).
import { readableAccountAccess, type CoderouterAccountAccess } from "../../../../../services/coderouter/accountAccess";
import { accountWriteAccess, teamPermissionRequired } from "../../../../../services/coderouter/accountAdministration";
import { removeAccount } from "../../../../../services/coderouter/accounts";
import { isAccountVisible } from "../../../../../services/coderouter/repository";
import { resolveCoderouterControlContext } from "../../../../../services/coderouter/requestContext";
import { captureCoderouterEvent } from "../../../../../services/coderouter/analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "../../../../../services/coderouter/observability";


const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function createDeleteAccountHandler(dependencies: {
  readonly resolve: typeof resolveCoderouterControlContext;
  readonly remove: (input: {
    readonly teamId: string;
    readonly accountId: string;
    readonly stackUserId?: string;
    readonly access: CoderouterAccountAccess;
  }) => ReturnType<typeof removeAccount>;
  readonly visible: typeof isAccountVisible;
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
    const team = resolved.value.team;
    let result;
    let visible = false;
    try {
      result = await dependencies.remove({
        teamId: team.teamId,
        accountId,
        stackUserId: resolved.value.user.id,
        access: accountWriteAccess(resolved.value),
      });
      // A member's delete reaches only their own private accounts. Any other
      // account they can see is refused by permission, not reported missing.
      if (!result.removed && !team.manageAccounts) {
        visible = await dependencies.visible({ teamId: team.teamId, accountId, access: readableAccountAccess(resolved.value.access) });
      }
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
    if (visible) return teamPermissionRequired(team, "change_shared_account");
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

export const DELETE = coderouterControlRoute("accounts", "/api/coderouter/accounts/[accountId]", createDeleteAccountHandler({
  resolve: resolveCoderouterControlContext,
  remove: async ({ teamId, accountId, stackUserId, access }) =>
    await removeAccount(teamId, accountId, stackUserId, access),
  visible: isAccountVisible,
}));
