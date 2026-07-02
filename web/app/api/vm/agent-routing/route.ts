import {
  validateSubrouterTenantKey,
  validateSubrouterUrl,
} from "../../../../services/vms/agentRouting";
import {
  jsonResponse,
  withAuthedVmApiRoute,
} from "../../../../services/vms/routeHelpers";
import {
  clearAgentRoutingConfig,
  getAgentRoutingState,
  runVmWorkflow,
  setAgentRoutingConfig,
  type AgentRoutingState,
} from "../../../../services/vms/workflows";

export const dynamic = "force-dynamic";

/**
 * Per-user subrouter agent-routing config for Cloud VMs. The tenant key is a
 * secret: it is accepted on PUT, stored backend-side, injected into VMs at
 * attach time, and only ever returned masked.
 */

export async function GET(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/agent-routing",
    { "cmux.vm.operation": "agent_routing_get" },
    "/api/vm/agent-routing GET failed",
    async ({ user }) => {
      const state = await runVmWorkflow(getAgentRoutingState(user.id));
      return jsonResponse(statePayload(state));
    },
  );
}

export async function PUT(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/agent-routing",
    { "cmux.vm.operation": "agent_routing_set" },
    "/api/vm/agent-routing PUT failed",
    async ({ user }) => {
      const body = await parseJsonBody(request);
      const url = validateSubrouterUrl(body.subrouterUrl ?? body.subrouter_url ?? body.url);
      if (!url.ok) {
        return jsonResponse({ error: "invalid_request", message: url.message }, 400);
      }
      const key = validateSubrouterTenantKey(
        body.subrouterTenantKey ?? body.subrouter_tenant_key ?? body.key,
      );
      if (!key.ok) {
        return jsonResponse({ error: "invalid_request", message: key.message }, 400);
      }
      const state = await runVmWorkflow(setAgentRoutingConfig({
        userId: user.id,
        subrouterUrl: url.value,
        subrouterTenantKey: key.value,
      }));
      return jsonResponse(statePayload(state));
    },
  );
}

export async function DELETE(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/agent-routing",
    { "cmux.vm.operation": "agent_routing_clear" },
    "/api/vm/agent-routing DELETE failed",
    async ({ user }) => {
      const state = await runVmWorkflow(clearAgentRoutingConfig(user.id));
      return jsonResponse(statePayload(state));
    },
  );
}

function statePayload(state: AgentRoutingState): Record<string, unknown> {
  return {
    configured: state.configured,
    subrouterUrl: state.subrouterUrl,
    subrouterTenantKeyMasked: state.subrouterTenantKeyMasked,
    updatedAt: state.updatedAt,
  };
}

async function parseJsonBody(request: Request): Promise<Record<string, unknown>> {
  try {
    const body = await request.json();
    return body && typeof body === "object" && !Array.isArray(body)
      ? body as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}
