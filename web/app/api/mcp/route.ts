// cmux Cloud remote MCP server (prototype), streamable HTTP transport in its
// stateless JSON form: each POST carries one JSON-RPC message and gets one JSON
// reply. There is no server-to-client stream, so GET answers 405.
//
// Auth is the same as `/api/vm`: the Stack bearer pair the cmux app sends, or a
// same-origin session cookie. OAuth for ChatGPT and Claude connectors is not
// wired yet; see the plugins issue for the plan.

import { setSpanAttributes } from "../../../services/telemetry";
import { handleCloudMcpMessage } from "../../../services/mcp/cloudMcp";
import { cloudMcpGatewayFor } from "../../../services/mcp/cloudMcpGateway";
import { vmModelPlaneRevoker } from "../../../services/vms/modelPlaneGateway";
import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../services/vms/routeHelpers";
import { runVmRoute } from "../../../services/vms/routeWorkflow";

// run_agent makes two guest calls of at most 30s each; leave room for auth and resume.
export const maxDuration = 120;

const MCP_ROUTE = "/api/mcp";

function withBearerChallenge(response: Response): Response {
  if (response.status !== 401) return response;
  const headers = new Headers(response.headers);
  headers.set("www-authenticate", 'Bearer realm="cmux"');
  return new Response(response.body, { status: 401, headers });
}

export async function POST(request: Request): Promise<Response> {
  const response = await withAuthedVmApiRoute(
    request,
    MCP_ROUTE,
    { "cmux.vm.operation": "mcp" },
    `${MCP_ROUTE} POST failed`,
    async ({ user, span }) => {
      let message: unknown;
      try {
        message = await request.json();
      } catch {
        return jsonResponse({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, 400);
      }
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      const listScopedToTeam = account.requestedBillingTeamId !== null || user.billingCustomerType === "team";
      const gateway = cloudMcpGatewayFor(
        {
          userId: user.id,
          teamIds: user.teamIds,
          billingTeamId: account.entitlements.billingTeamId,
          listBillingTeamId: listScopedToTeam ? account.entitlements.billingTeamId : null,
          maxActiveVms: account.entitlements.maxActiveVms,
          planId: account.entitlements.planId,
        },
        (program) => runVmRoute(program, { request }),
        vmModelPlaneRevoker(),
      );
      const method = message && typeof message === "object" && "method" in message ? String(message.method) : "";
      setSpanAttributes(span, { "cmux.mcp.method": method.slice(0, 64) });
      const reply = await handleCloudMcpMessage(gateway, message);
      if (!reply) return new Response(null, { status: 202 });
      return jsonResponse(reply);
    },
  );
  return withBearerChallenge(response);
}

export function GET(): Response {
  return new Response(null, { status: 405, headers: { allow: "POST" } });
}
