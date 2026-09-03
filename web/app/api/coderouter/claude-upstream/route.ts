import {
  deleteClaudeUpstream,
  describeClaudeUpstream,
  parseClaudeUpstreamInput,
  putClaudeUpstream,
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

const MAX_BODY_BYTES = 64 * 1_024;

export type ClaudeUpstreamRouteDependencies = {
  readonly resolveUsageTeam: typeof resolveCoderouterUsageTeam;
  readonly resolveContext: typeof resolveCodeRouterRequestContext;
  readonly describe: typeof describeClaudeUpstream;
  readonly put: typeof putClaudeUpstream;
  readonly remove: typeof deleteClaudeUpstream;
};

const defaultDependencies: ClaudeUpstreamRouteDependencies = {
  resolveUsageTeam: resolveCoderouterUsageTeam,
  resolveContext: resolveCodeRouterRequestContext,
  describe: describeClaudeUpstream,
  put: putClaudeUpstream,
  remove: deleteClaudeUpstream,
};

export function makeClaudeUpstreamHandlers(
  dependencies: ClaudeUpstreamRouteDependencies = defaultDependencies,
) {
  async function GET(request: Request): Promise<Response> {
    const resolved = await dependencies.resolveUsageTeam(request);
    if (!resolved.ok) return resolved.response;
    try {
      const upstream = await dependencies.describe(resolved.teamId);
      return Response.json(
        { teamId: resolved.teamId, upstream },
        { headers: { "cache-control": "no-store" } },
      );
    } catch (error) {
      reportCoderouterFailure("rds", error, { operation: "describe_claude_upstream" });
      return unavailable("coderouter could not load the Claude upstream. Retry shortly.");
    }
  }

  async function PUT(request: Request): Promise<Response> {
    const resolved = await dependencies.resolveContext(request);
    if (!resolved.ok) return resolved.response;
    const length = Number(request.headers.get("content-length") ?? "0");
    if (Number.isFinite(length) && length > MAX_BODY_BYTES) {
      return Response.json({ error: "payload_too_large" }, { status: 413 });
    }
    const bytes = new Uint8Array(await request.arrayBuffer());
    if (bytes.byteLength > MAX_BODY_BYTES) {
      return Response.json({ error: "payload_too_large" }, { status: 413 });
    }
    let value: unknown;
    try {
      value = JSON.parse(new TextDecoder().decode(bytes));
    } catch {
      return Response.json({ error: "invalid_request" }, { status: 400 });
    }
    const input = parseClaudeUpstreamInput(value);
    if (!input) {
      return Response.json({ error: "invalid_request" }, { status: 400 });
    }
    const teamId = resolved.value.team.teamId;
    const stackUserId = resolved.value.user.id;
    try {
      const previous = await dependencies.describe(teamId);
      const upstream = await dependencies.put(teamId, stackUserId, input);
      captureCoderouterEvent({
        event: "coderouter_claude_upstream_set",
        userId: stackUserId,
        teamId,
        properties: { upstream_kind: input.kind, replaced: previous !== null },
      });
      addCoderouterBreadcrumb("account", "Claude upstream stored", {
        upstream_kind: input.kind,
        replaced: previous !== null,
      });
      return Response.json(
        { teamId, upstream },
        { status: previous ? 200 : 201, headers: { "cache-control": "no-store" } },
      );
    } catch (error) {
      reportCoderouterFailure("rds", error, { operation: "put_claude_upstream" });
      return unavailable("coderouter could not store the Claude upstream. Nothing was changed; retry shortly.");
    }
  }

  async function DELETE(request: Request): Promise<Response> {
    const resolved = await dependencies.resolveContext(request);
    if (!resolved.ok) return resolved.response;
    const teamId = resolved.value.team.teamId;
    let result;
    try {
      result = await dependencies.remove(teamId);
    } catch (error) {
      reportCoderouterFailure("rds", error, { operation: "remove_claude_upstream" });
      return unavailable("coderouter could not remove the Claude upstream. Nothing was changed; retry shortly.");
    }
    if (!result.removed) {
      return Response.json(
        { error: "not_found", message: "This team has no Claude upstream.", retryable: false },
        { status: 404, headers: { "cache-control": "no-store" } },
      );
    }
    captureCoderouterEvent({
      event: "coderouter_claude_upstream_removed",
      userId: resolved.value.user.id,
      teamId,
      properties: {},
    });
    addCoderouterBreadcrumb("account", "Claude upstream removed");
    return Response.json(result, { headers: { "cache-control": "no-store" } });
  }

  return { GET, PUT, DELETE };
}

function unavailable(message: string): Response {
  return Response.json(
    { error: "claude_upstream_unavailable", message, retryable: true },
    { status: 503, headers: { "cache-control": "no-store", "retry-after": "5" } },
  );
}

const handlers = makeClaudeUpstreamHandlers();
export const GET = handlers.GET;
export const PUT = handlers.PUT;
export const DELETE = handlers.DELETE;
