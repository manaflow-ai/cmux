// One Claude upstream account: rename or enable/disable (PATCH), remove
// (DELETE). Both need `manageAccounts` on the team.
import {
  isClaudeAccountId,
  parseClaudeAccountPatch,
  removeClaudeAccount,
  updateClaudeAccount,
} from "../../../../../services/coderouter/claudeUpstream";
import { resolveCodeRouterRequestContext } from "../../../../../services/coderouter/requestContext";
import { captureCoderouterEvent } from "../../../../../services/coderouter/analytics";
import {
  captureCoderouterProductEvent,
  coderouterClaudeUpstreamEvent,
} from "../../../../../services/coderouter/productAnalytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "../../../../../services/coderouter/observability";
import { claudeUpstreamUnavailable, readJsonBody } from "../route";

export type ClaudeAccountRouteDependencies = {
  readonly resolveContext: typeof resolveCodeRouterRequestContext;
  readonly update: typeof updateClaudeAccount;
  readonly remove: typeof removeClaudeAccount;
};

const defaultDependencies: ClaudeAccountRouteDependencies = {
  resolveContext: resolveCodeRouterRequestContext,
  update: updateClaudeAccount,
  remove: removeClaudeAccount,
};

type Context = { params: Promise<{ accountId: string }> };

export function makeClaudeAccountHandlers(
  dependencies: ClaudeAccountRouteDependencies = defaultDependencies,
) {
  async function PATCH(request: Request, context: Context): Promise<Response> {
    const resolved = await dependencies.resolveContext(request);
    if (!resolved.ok) return resolved.response;
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
      const account = await dependencies.update(teamId, accountId, patch);
      if (!account) return notFound();
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
    const { accountId } = await context.params;
    if (!isClaudeAccountId(accountId)) {
      return Response.json({ error: "invalid_request" }, { status: 400 });
    }
    const teamId = resolved.value.team.teamId;
    let result;
    try {
      result = await dependencies.remove(teamId, accountId);
    } catch (error) {
      reportCoderouterFailure("rds", error, { operation: "remove_claude_account" });
      return claudeUpstreamUnavailable("coderouter could not remove the Claude upstream account. Nothing was changed; retry shortly.");
    }
    if (!result.removed) return notFound();
    captureCoderouterEvent({
      event: "coderouter_claude_upstream_removed",
      userId: resolved.value.user.id,
      teamId,
      properties: {},
    });
    captureCoderouterProductEvent(coderouterClaudeUpstreamEvent({
      kind: "removed",
      stackUserId: resolved.value.user.id,
      teamId,
    }));
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
export const PATCH = handlers.PATCH;
export const DELETE = handlers.DELETE;
