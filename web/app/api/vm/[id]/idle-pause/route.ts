import {
  jsonResponse,
  resolveVmRouteAccountScope,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { setVmIdlePause } from "../../../../../services/vms/workflows";
import { parseIdlePauseBody } from "../../../../../services/vms/idlePauseRoute";

/**
 * Set how long a machine may sit idle before it pauses by itself
 * (services/vms/idlePause.ts): `{ "minutes": 15 | 30 | 60 | 120 }`, or `0` /
 * `"off"` to never auto-pause it. cmux.com does not pause idle machines yet,
 * so only Off is stored; a timeout answers 409 `idle_pause_unavailable`.
 * Answers `{ id, idlePauseMinutes }`.
 */
export async function PUT(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/idle-pause",
    { "cmux.vm.operation": "idle_pause_update" },
    "/api/vm/[id]/idle-pause PUT failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return vmErrorResponse({
          error: "vm_invalid_json",
          status: 400,
          message: "The idle pause setting expected a JSON object body.",
          action: "Send `{ \"minutes\": \"off\" }`.",
        });
      }
      const parsed = parseIdlePauseBody(body);
      if (!parsed.ok) return parsed.response;
      setSpanAttributes(span, { "cmux.vm.id": id, "cmux.vm.idle_pause_minutes": parsed.minutes });
      const run = await runVmRoute(setVmIdlePause({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        callerPlanId: account.entitlements.planId,
        minutes: parsed.minutes,
      }), { request });
      if (!run.ok) return run.response;
      return jsonResponse({ id: run.value.providerVmId, idlePauseMinutes: run.value.idlePauseMinutes });
    },
  );
}
