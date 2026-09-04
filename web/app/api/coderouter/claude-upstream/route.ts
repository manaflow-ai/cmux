import { coderouterControlRoute } from "@/services/coderouter/requestTelemetry";
// Team Claude upstream accounts: list, add, remove all. One account is
// addressed under ./[accountId]. Any team member may read; `manageAccounts`
// (every member today) may write. Secrets never leave the server: responses
// carry masked identifiers only.
import {
  addClaudeAccount,
  listClaudeAccounts,
  parseClaudeUpstreamInput,
  removeAllClaudeAccounts,
} from "../../../../services/coderouter/claudeUpstream";
import {
  resolveCoderouterUsageTeam,
  resolveCodeRouterRequestContext,
} from "../../../../services/coderouter/requestContext";
import { captureCoderouterEvent } from "../../../../services/coderouter/analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "../../../../services/coderouter/observability";

export const MAX_CLAUDE_UPSTREAM_BODY_BYTES = 64 * 1_024;

export type ClaudeUpstreamRouteDependencies = {
  readonly resolveUsageTeam: typeof resolveCoderouterUsageTeam;
  readonly resolveContext: typeof resolveCodeRouterRequestContext;
  readonly list: typeof listClaudeAccounts;
  readonly add: typeof addClaudeAccount;
  readonly removeAll: typeof removeAllClaudeAccounts;
};

const defaultDependencies: ClaudeUpstreamRouteDependencies = {
  resolveUsageTeam: resolveCoderouterUsageTeam,
  resolveContext: resolveCodeRouterRequestContext,
  list: listClaudeAccounts,
  add: addClaudeAccount,
  removeAll: removeAllClaudeAccounts,
};

export function makeClaudeUpstreamHandlers(
  dependencies: ClaudeUpstreamRouteDependencies = defaultDependencies,
) {
  async function GET(request: Request): Promise<Response> {
    const resolved = await dependencies.resolveUsageTeam(request);
    if (!resolved.ok) return resolved.response;
    try {
      const accounts = await dependencies.list(resolved.teamId);
      return Response.json(
        // `upstream` mirrors the first account for clients written against the
        // single-upstream contract; new clients read `accounts`.
        { teamId: resolved.teamId, accounts, upstream: accounts[0] ?? null },
        { headers: { "cache-control": "no-store" } },
      );
    } catch (error) {
      reportCoderouterFailure("rds", error, { operation: "list_claude_accounts" });
      return claudeUpstreamUnavailable("coderouter could not load the Claude upstream accounts. Retry shortly.");
    }
  }

  /** Adds an account. `PUT` is accepted as an alias for older clients. */
  async function POST(request: Request): Promise<Response> {
    const resolved = await dependencies.resolveContext(request);
    if (!resolved.ok) return resolved.response;
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    const input = parseClaudeUpstreamInput(body.value);
    if (!input) {
      return Response.json({ error: "invalid_request" }, { status: 400 });
    }
    const teamId = resolved.value.team.teamId;
    const stackUserId = resolved.value.user.id;
    try {
      const before = await dependencies.list(teamId);
      const account = await dependencies.add(teamId, stackUserId, input);
      captureCoderouterEvent({
        event: "coderouter_claude_upstream_set",
        userId: stackUserId,
        teamId,
        properties: { upstream_kind: input.kind, replaced: false },
      });
      addCoderouterBreadcrumb("account", "Claude upstream account added", {
        upstream_kind: input.kind,
        accounts_total: before.length + 1,
      });
      return Response.json(
        { teamId, account, upstream: account, accountsTotal: before.length + 1 },
        { status: 201, headers: { "cache-control": "no-store" } },
      );
    } catch (error) {
      reportCoderouterFailure("rds", error, { operation: "add_claude_account" });
      return claudeUpstreamUnavailable("coderouter could not store the Claude upstream account. Nothing was changed; retry shortly.");
    }
  }

  /** Removes every account of the team. */
  async function DELETE(request: Request): Promise<Response> {
    const resolved = await dependencies.resolveContext(request);
    if (!resolved.ok) return resolved.response;
    const teamId = resolved.value.team.teamId;
    let result;
    try {
      result = await dependencies.removeAll(teamId);
    } catch (error) {
      reportCoderouterFailure("rds", error, { operation: "remove_all_claude_accounts" });
      return claudeUpstreamUnavailable("coderouter could not remove the Claude upstream accounts. Nothing was changed; retry shortly.");
    }
    if (result.removed === 0) {
      return Response.json(
        { error: "not_found", message: "This team has no Claude upstream accounts.", retryable: false },
        { status: 404, headers: { "cache-control": "no-store" } },
      );
    }
    captureCoderouterEvent({
      event: "coderouter_claude_upstream_removed",
      userId: resolved.value.user.id,
      teamId,
      properties: {},
    });
    addCoderouterBreadcrumb("account", "Claude upstream accounts removed", { removed: result.removed });
    return Response.json(
      { removed: true, count: result.removed },
      { headers: { "cache-control": "no-store" } },
    );
  }

  return { GET, POST, PUT: POST, DELETE };
}

export async function readJsonBody(request: Request): Promise<
  | { ok: true; value: unknown }
  | { ok: false; response: Response }
> {
  const length = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(length) && length > MAX_CLAUDE_UPSTREAM_BODY_BYTES) {
    return { ok: false, response: Response.json({ error: "payload_too_large" }, { status: 413 }) };
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > MAX_CLAUDE_UPSTREAM_BODY_BYTES) {
    return { ok: false, response: Response.json({ error: "payload_too_large" }, { status: 413 }) };
  }
  try {
    return { ok: true, value: JSON.parse(new TextDecoder().decode(bytes)) };
  } catch {
    return { ok: false, response: Response.json({ error: "invalid_request" }, { status: 400 }) };
  }
}

export function claudeUpstreamUnavailable(message: string): Response {
  return Response.json(
    { error: "claude_upstream_unavailable", message, retryable: true },
    { status: 503, headers: { "cache-control": "no-store", "retry-after": "5" } },
  );
}

const handlers = makeClaudeUpstreamHandlers();
export const GET = coderouterControlRoute("claude_upstream", "/api/coderouter/claude-upstream", handlers.GET);
export const POST = coderouterControlRoute("claude_upstream", "/api/coderouter/claude-upstream", handlers.POST);
export const PUT = coderouterControlRoute("claude_upstream", "/api/coderouter/claude-upstream", handlers.PUT);
export const DELETE = coderouterControlRoute("claude_upstream", "/api/coderouter/claude-upstream", handlers.DELETE);
