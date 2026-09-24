import { coderouterControlRoute } from "@/services/coderouter/requestTelemetry";
// One Claude upstream account: rename or enable/disable (PATCH), remove
// (DELETE). A member changes their own private accounts; a shared account
// needs account administration (accountAdministration.ts).
import {
  isClaudeAccountId,
  listClaudeAccounts,
  parseClaudeAccountPatch,
  removeClaudeAccount,
  updateClaudeAccount,
} from "../../../../../services/coderouter/claudeUpstream";
import { readableAccountAccess } from "../../../../../services/coderouter/accountAccess";
import { accountWriteAccess, teamPermissionRequired } from "../../../../../services/coderouter/accountAdministration";
import {
  resolveCoderouterControlContext,
  type CodeRouterControlContext,
} from "../../../../../services/coderouter/requestContext";
import { captureCoderouterEvent } from "../../../../../services/coderouter/analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "../../../../../services/coderouter/observability";
import { claudeUpstreamUnavailable, readJsonBody } from "../route";

export type ClaudeAccountRouteDependencies = {
  readonly resolveContext: typeof resolveCoderouterControlContext;
  readonly list: typeof listClaudeAccounts;
  readonly update: typeof updateClaudeAccount;
  readonly remove: typeof removeClaudeAccount;
};

const defaultDependencies: ClaudeAccountRouteDependencies = {
  resolveContext: resolveCoderouterControlContext,
  list: listClaudeAccounts,
  update: updateClaudeAccount,
  remove: removeClaudeAccount,
};

type Context = { params: Promise<{ accountId: string }> };

export function makeClaudeAccountHandlers(
  dependencies: ClaudeAccountRouteDependencies = defaultDependencies,
) {
  // A write that reached no row is a 404, unless the caller can see the
  // account and was only kept from it by account administration.
  async function unwritable(context: CodeRouterControlContext, accountId: string): Promise<Response> {
    if (context.team.manageAccounts) return notFound();
    const visible = await dependencies.list(context.team.teamId, readableAccountAccess(context.access));
    if (!visible.some(account => account.id === accountId)) return notFound();
    return teamPermissionRequired(context.team, "change_shared_account");
  }

  async function PATCH(request: Request, context: Context): Promise<Response> {
    const resolved = await dependencies.resolveContext(request);
    if (!resolved.ok) return resolved.response;
    const access = accountWriteAccess(resolved.value);
    const { accountId } = await context.params;
    if (!isClaudeAccountId(accountId)) {
      return Response.json({ error: "invalid_request" }, { status: 400 });
    }
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    const patch = parseClaudeAccountPatch(body.value);
    if (!patch) {
      return Response.json({ error: "invalid_request" }, { status: 400 });
    }
    const teamId = resolved.value.team.teamId;
    try {
      const account = await dependencies.update(teamId, accountId, patch, access);
      if (!account) return await unwritable(resolved.value, accountId);
      addCoderouterBreadcrumb("account", "Claude upstream account updated", {
        ...(patch.state ? { state: patch.state } : {}),
        relabeled: patch.label !== undefined,
      });
      return Response.json({ teamId, account }, { headers: { "cache-control": "no-store" } });
    } catch (error) {
      reportCoderouterFailure("rds", error, { operation: "update_claude_account" });
      return claudeUpstreamUnavailable("coderouter could not update the Claude upstream account. Nothing was changed; retry shortly.");
    }
  }

  async function DELETE(request: Request, context: Context): Promise<Response> {
    const resolved = await dependencies.resolveContext(request);
    if (!resolved.ok) return resolved.response;
    const access = accountWriteAccess(resolved.value);
    const { accountId } = await context.params;
    if (!isClaudeAccountId(accountId)) {
      return Response.json({ error: "invalid_request" }, { status: 400 });
    }
    const teamId = resolved.value.team.teamId;
    let refused: Response | null = null;
    try {
      const result = await dependencies.remove(teamId, accountId, access);
      if (!result.removed) refused = await unwritable(resolved.value, accountId);
    } catch (error) {
      reportCoderouterFailure("rds", error, { operation: "remove_claude_account" });
      return claudeUpstreamUnavailable("coderouter could not remove the Claude upstream account. Nothing was changed; retry shortly.");
    }
    if (refused) return refused;
    captureCoderouterEvent({
      event: "coderouter_claude_upstream_removed",
      userId: resolved.value.user.id,
      teamId,
      properties: {},
    });
    addCoderouterBreadcrumb("account", "Claude upstream account removed");
    return Response.json({ removed: true, count: 1 }, { headers: { "cache-control": "no-store" } });
  }

  return { PATCH, DELETE };
}

function notFound(): Response {
  return Response.json(
    { error: "not_found", message: "This team has no Claude upstream account with that id.", retryable: false },
    { status: 404, headers: { "cache-control": "no-store" } },
  );
}

const handlers = makeClaudeAccountHandlers();
export const PATCH = coderouterControlRoute("claude_upstream", "/api/coderouter/claude-upstream/[accountId]", handlers.PATCH);
export const DELETE = coderouterControlRoute("claude_upstream", "/api/coderouter/claude-upstream/[accountId]", handlers.DELETE);
