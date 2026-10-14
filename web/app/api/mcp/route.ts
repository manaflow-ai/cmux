// cmux Cloud remote MCP server (prototype), streamable HTTP transport in its
// stateless JSON form: each POST carries one JSON-RPC message (or a batch) and
// gets a JSON reply. There is no server-to-client stream, so GET answers 405.
//
// Auth is the same as `/api/vm`: the Stack bearer pair the cmux app sends, or a
// same-origin session cookie. OAuth for ChatGPT and Claude connectors is not
// wired yet; see #16567 for the plan.

import { recordSpanError, setSpanAttributes } from "../../../services/telemetry";
import { handleCloudMcpBody } from "../../../services/mcp/cloudMcp";
import { cloudMcpGatewayFor, toolErrorFromResponse } from "../../../services/mcp/cloudMcpGateway";
import type { AuthedUser } from "../../../services/vms/auth";
import { isVmBillingTeamResolutionError, resolveVmEntitlements } from "../../../services/vms/entitlements";
import { vmModelPlaneRevoker } from "../../../services/vms/modelPlaneGateway";
import {
  jsonResponse,
  requestedVmTeamIdFromRequest,
  resolveVmRouteAccountScope,
  vmBillingTeamErrorResponse,
  withAuthedVmApiRoute,
} from "../../../services/vms/routeHelpers";
import { annotateVmRequestBilling } from "../../../services/vms/requestContext";
import { runVmRoute } from "../../../services/vms/routeWorkflow";

// run_agent makes up to three guest calls of at most 30s each; leave room for auth and resume.
export const maxDuration = 120;

const MCP_ROUTE = "/api/mcp";
// Tool arguments are capped at 16 KiB each; anything far beyond that is not a tool call.
const MAX_BODY_BYTES = 256 * 1024;

function withBearerChallenge(response: Response): Response {
  if (response.status !== 401) return response;
  const headers = new Headers(response.headers);
  headers.set("www-authenticate", 'Bearer realm="cmux"');
  return new Response(response.body, { status: 401, headers });
}

function rpcFailure(code: number, message: string, status: number): Response {
  return jsonResponse({ jsonrpc: "2.0", id: null, error: { code, message } }, status);
}

/** The list scope `GET /api/vm` uses: entitlements only for a requested team or a team account. */
async function listScopeFor(user: AuthedUser, request: Request): Promise<string | null> {
  const requestedBillingTeamId = requestedVmTeamIdFromRequest(request);
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

export async function POST(request: Request): Promise<Response> {
  const response = await withAuthedVmApiRoute(
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
      const gateway = cloudMcpGatewayFor(
        {
          userId: user.id,
          teamIds: user.teamIds,
          listScope: () => listScopeFor(user, request),
          accessScope: async () => {
            const account = resolveVmRouteAccountScope(user, request);
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
      setSpanAttributes(span, { "cmux.mcp.method": method.slice(0, 64) });
      const reply = await handleCloudMcpBody(gateway, body, (error) => {
        recordSpanError(span, error);
        console.error(`${MCP_ROUTE} tool call failed`, error);
      });
      if (!reply) return new Response(null, { status: 202 });
      return jsonResponse(reply);
    },
  );
  return withBearerChallenge(response);
}

export function GET(): Response {
  return new Response(null, { status: 405, headers: { allow: "POST" } });
}
