import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { getVmNetworkPolicy, updateVmNetworkPolicy } from "../../../../../services/vms/workflows";
import { networkPolicyResponseBody, parseNetworkPolicyBody } from "../../../../../services/vms/networkPolicyRoute";

/** A machine's outbound network policy and whether the provider has applied it. */
export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/network",
    { "cmux.vm.operation": "network_policy_get" },
    "/api/vm/[id]/network GET failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      span.setAttribute("cmux.vm.id", id);
      const run = await runVmRoute(getVmNetworkPolicy({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        callerPlanId: account.entitlements.planId,
      }), { request });
      if (!run.ok) return run.response;
      return jsonResponse(networkPolicyResponseBody(run.value));
    },
  );
}

/**
 * Replace a machine's outbound network policy. Applies live on a running or
 * paused machine with no restart; the stored policy is the source of truth,
 * and a failed apply is reported in `applied` and retried by the next PUT.
 */
export async function PUT(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/network",
    { "cmux.vm.operation": "network_policy_update" },
    "/api/vm/[id]/network PUT failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return jsonResponse({ error: "invalid JSON body" }, 400);
      }
      const parsed = parseNetworkPolicyBody(body);
      if (!parsed.ok) return parsed.response;
      span.setAttribute("cmux.vm.id", id);
      span.setAttribute("cmux.vm.network.mode", parsed.policy.mode);
      const run = await runVmRoute(updateVmNetworkPolicy({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        callerPlanId: account.entitlements.planId,
        policy: parsed.policy,
      }), { request });
      if (!run.ok) return run.response;
      return jsonResponse(networkPolicyResponseBody(run.value));
    },
  );
}
