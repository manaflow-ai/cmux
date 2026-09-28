import * as Effect from "effect/Effect";
import {
  jsonResponse,
  resolveVmRouteAccountScope,
  runAfterResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { setVmAgentUpdates } from "../../../../../services/vms/workflows";
import { parseAgentUpdatesBody } from "../../../../../services/vms/agentUpdatesRoute";

/**
 * Set whether a machine keeps its image's coding-agent versions ("image") or
 * updates them to npm's latest on attach ("latest"). The row is the source of
 * truth; a running machine is told after the response, and every attach of an
 * opted-in machine re-sends it. Answers with the machine entry.
 */
export async function PUT(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/agent-updates",
    { "cmux.vm.operation": "agent_updates_update" },
    "/api/vm/[id]/agent-updates PUT failed",
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
      const parsed = parseAgentUpdatesBody(body);
      if (!parsed.ok) return parsed.response;
      span.setAttribute("cmux.vm.id", id);
      span.setAttribute("cmux.vm.agent_updates", parsed.setting);
      const run = await runVmRoute(setVmAgentUpdates({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        callerPlanId: account.entitlements.planId,
        agentUpdates: parsed.setting,
        deferAfterResponse: (work) => runAfterResponse(() => Effect.runPromise(work)),
      }), { request });
      if (!run.ok) return run.response;
      return jsonResponse(run.value);
    },
  );
}
