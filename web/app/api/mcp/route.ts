// cmux Cloud remote MCP server, streamable HTTP transport in its stateless
// JSON form: each POST carries one JSON-RPC message (or a batch) and gets a
// JSON reply. There is no server-to-client stream, so GET answers 405.
//
// Two kinds of caller:
// - An MCP host (ChatGPT, Codex, Claude) with an OAuth access token from
//   `/api/oauth/token`. The token's grant fixes the user, the billing team and
//   the scopes; `/.well-known/oauth-protected-resource/api/mcp` tells a host
//   without a token where to get one.
// - The cmux app with its Stack bearer pair, or a same-origin session cookie,
//   with every scope.
//
// Machine lifecycle tools run the `/api/vm` route handlers in process as the
// already-authenticated caller, so validation, ownership, billing and plan
// rules have one implementation.

import { recordSpanError, setSpanAttributes } from "../../../services/telemetry";
import { handleCloudMcpBody } from "../../../services/mcp/cloudMcp";
import { cloudMcpProfileId } from "../../../services/mcp/cloudMcpCloudTools";
import {
  cloudMcpGatewayFor,
  toolErrorFromResponse,
  type CloudMcpVmRouteCaller,
} from "../../../services/mcp/cloudMcpGateway";
import { authenticateMcpBearer, type McpOauthCaller } from "../../../services/mcp/mcpAuth";
import { bearerChallenge } from "../../../services/mcp/oauth";
import { corsPreflight, mcpPublicOrigin, withCors } from "../../../services/mcp/oauthRoutes";
import { mcpOauthDbStore } from "../../../services/mcp/oauthStore";
import type { AuthedUser } from "../../../services/vms/auth";
import { CloudMcpToolError } from "../../../services/mcp/cloudMcpShared";
import { isVmBillingTeamResolutionError, resolveVmEntitlements } from "../../../services/vms/entitlements";
import { vmModelPlaneRevoker } from "../../../services/vms/modelPlaneGateway";
import { runAsPreauthenticatedVmUser } from "../../../services/vms/preauthenticatedUser";
import {
  jsonResponse,
  requestedVmTeamIdFromRequest,
  resolveVmRouteAccountScope,
  vmBillingTeamErrorResponse,
  withAuthedVmApiRoute,
} from "../../../services/vms/routeHelpers";
import { annotateVmRequestBilling } from "../../../services/vms/requestContext";
import { runVmRoute } from "../../../services/vms/routeWorkflow";
import { GET as listVmsRoute, POST as createVmRoute } from "../vm/route";
import { DELETE as deleteVmRoute, GET as getVmRoute } from "../vm/[id]/route";
import { POST as pauseVmRoute } from "../vm/[id]/pause/route";
import { POST as resumeVmRoute } from "../vm/[id]/resume/route";

// create_machine runs the full create path (provider boot included); leave room for it.
export const maxDuration = 300;

const MCP_ROUTE = "/api/mcp";
// Tool arguments are capped at 16 KiB each; anything far beyond that is not a tool call.
const MAX_BODY_BYTES = 256 * 1024;

function unauthorizedMcp(origin: string, error?: "invalid_token"): Response {
  return new Response(JSON.stringify({ error: error ?? "unauthorized" }), {
    status: 401,
    headers: { "content-type": "application/json", "www-authenticate": bearerChallenge(origin, error) },
  });
}

function withBearerChallenge(response: Response, origin: string): Response {
  if (response.status !== 401) return response;
  const headers = new Headers(response.headers);
  headers.set("www-authenticate", bearerChallenge(origin));
  return new Response(response.body, { status: 401, headers });
}

function rpcFailure(code: number, message: string, status: number): Response {
  return jsonResponse({ jsonrpc: "2.0", id: null, error: { code, message } }, status);
}

/** The billing team the caller acts for: fixed by the OAuth grant, or chosen per request by the cmux app. */
function teamIdFor(request: Request, oauth: McpOauthCaller | null): string | null {
  return oauth ? oauth.grant.teamId : requestedVmTeamIdFromRequest(request);
}

/** The list scope `GET /api/vm` uses: entitlements only for a requested team or a team account. */
async function listScopeFor(user: AuthedUser, requestedBillingTeamId: string | null): Promise<string | null> {
  if (!requestedBillingTeamId && user.billingCustomerType !== "team") return null;
  try {
    const entitlements = resolveVmEntitlements(user, process.env, { requestedBillingTeamId });
    annotateVmRequestBilling(entitlements);
    return entitlements.billingTeamId;
  } catch (err) {
    if (isVmBillingTeamResolutionError(err)) throw await toolErrorFromResponse(vmBillingTeamErrorResponse(err));
    throw err;
  }
}

type VmHandler = (request: Request, context: { params: Promise<{ id: string }> }) => Promise<Response>;

function vmHandlerFor(method: string, path: string): { handler: VmHandler; id: string } | null {
  if (path === "/api/vm") {
    if (method === "GET") return { handler: (request) => listVmsRoute(request), id: "" };
    if (method === "POST") return { handler: (request) => createVmRoute(request), id: "" };
    return null;
  }
  const match = /^\/api\/vm\/([^/]+)(?:\/(pause|resume))?$/.exec(path);
  if (!match) return null;
  const id = decodeURIComponent(match[1]!);
  if (match[2] === "pause" && method === "POST") return { handler: pauseVmRoute, id };
  if (match[2] === "resume" && method === "POST") return { handler: resumeVmRoute, id };
  if (!match[2] && method === "GET") return { handler: getVmRoute, id };
  if (!match[2] && method === "DELETE") return { handler: deleteVmRoute, id };
  return null;
}

/** Calls an `/api/vm` handler in process as `user`, billed to `teamId`. */
function vmRouteCallerFor(user: AuthedUser, teamId: string | null, request: Request, origin: string): CloudMcpVmRouteCaller {
  return async ({ method, path, body, idempotencyKey }) => {
    const target = vmHandlerFor(method, path);
    if (!target) throw new Error(`No in-process VM route for ${method} ${path}`);
    const headers = new Headers({ accept: "application/json" });
    if (body) headers.set("content-type", "application/json");
    if (teamId) headers.set("x-cmux-team-id", teamId);
    if (idempotencyKey) headers.set("idempotency-key", idempotencyKey);
    const language = request.headers.get("accept-language");
    if (language) headers.set("accept-language", language);
    const inner = new Request(`${origin}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
    return runAsPreauthenticatedVmUser(user, () => target.handler(inner, { params: Promise.resolve({ id: target.id }) }));
  };
}

function settingsFor(oauth: McpOauthCaller | null) {
  const store = mcpOauthDbStore();
  if (!oauth) {
    return {
      read: async () => ({}),
      write: async () => {
        throw new CloudMcpToolError("settings_unavailable", "Settings belong to an OAuth connection; this session has none.");
      },
    };
  }
  return {
    read: () => store.readGrantSettings(oauth.grant.id),
    write: (values: Record<string, unknown>) => store.writeGrantSettings(oauth.grant.id, values),
  };
}

async function handleMcp(request: Request, origin: string, oauth: McpOauthCaller | null): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    MCP_ROUTE,
    { "cmux.vm.operation": "mcp" },
    `${MCP_ROUTE} POST failed`,
    async ({ user, span }) => {
      const declaredLength = Number(request.headers.get("content-length") ?? 0);
      if (declaredLength > MAX_BODY_BYTES) return rpcFailure(-32600, "Request too large", 413);
      const raw = await request.text();
      if (Buffer.byteLength(raw, "utf8") > MAX_BODY_BYTES) return rpcFailure(-32600, "Request too large", 413);
      let body: unknown;
      try {
        body = JSON.parse(raw);
      } catch {
        return rpcFailure(-32700, "Parse error", 400);
      }
      const teamId = teamIdFor(request, oauth);
      const teamName = user.teams.find((team) => team.id === teamId)?.displayName ?? null;
      const gateway = cloudMcpGatewayFor(
        {
          userId: user.id,
          teamIds: user.teamIds,
          scopes: oauth ? oauth.grant.scopes : null,
          teamName,
          profile: {
            id: cloudMcpProfileId(user.id, teamId),
            ...(user.displayName ? { name: user.displayName } : {}),
            ...(user.primaryEmail ? { email: user.primaryEmail } : {}),
            ...(teamName ? { nickname: teamName } : {}),
          },
          insufficientScopeChallenge: (scope) => bearerChallenge(origin, "insufficient_scope", scope, `Reconnect cmux and allow ${scope}`),
          settings: settingsFor(oauth),
          vmRoute: vmRouteCallerFor(user, teamId, request, origin),
          listScope: () => listScopeFor(user, teamId),
          accessScope: async () => {
            const account = resolveVmRouteAccountScope(user, request, { requestedBillingTeamId: teamId });
            if (!account.ok) throw await toolErrorFromResponse(account.response);
            return {
              billingTeamId: account.entitlements.billingTeamId,
              maxActiveVms: account.entitlements.maxActiveVms,
              planId: account.entitlements.planId,
            };
          },
        },
        (program) => runVmRoute(program, { request }),
        vmModelPlaneRevoker(),
      );
      const method = body && typeof body === "object" && "method" in body ? String(body.method) : Array.isArray(body) ? "batch" : "";
      setSpanAttributes(span, {
        "cmux.mcp.method": method.slice(0, 64),
        "cmux.mcp.auth": oauth ? "oauth" : "stack",
        "cmux.mcp.client_id": oauth?.grant.clientId.slice(0, 120),
      });
      const reply = await handleCloudMcpBody(gateway, body, (error) => {
        recordSpanError(span, error);
        console.error(`${MCP_ROUTE} tool call failed`, error);
      });
      if (!reply) return new Response(null, { status: 202 });
      return jsonResponse(reply);
    },
  );
}

export async function POST(request: Request): Promise<Response> {
  const origin = mcpPublicOrigin(request);
  const auth = await authenticateMcpBearer(request, mcpOauthDbStore());
  if (auth.kind === "invalid") return withCors(unauthorizedMcp(origin, "invalid_token"));
  const response = auth.kind === "oauth"
    ? await runAsPreauthenticatedVmUser(auth.caller.user, () => handleMcp(request, origin, auth.caller))
    : await handleMcp(request, origin, null);
  return withCors(withBearerChallenge(response, origin));
}

export function GET(): Response {
  return new Response(null, { status: 405, headers: { allow: "POST" } });
}

export function OPTIONS(): Response {
  return corsPreflight();
}
