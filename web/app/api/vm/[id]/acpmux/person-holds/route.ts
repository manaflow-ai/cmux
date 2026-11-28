import {
  resolveVmRouteAccountScope,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../../services/telemetry";
import { runVmRoute } from "../../../../../../services/vms/routeWorkflow";
import { acpmuxPersonHoldsVm } from "../../../../../../services/vms/acpmuxPersonKey";
import { acpmuxOutcomeResponse } from "../../../../../../services/vms/acpmuxPersonKeyRoute";
import { isAcpmuxNonce } from "../../../../../../services/vms/drivers/acpmuxPersonKey";
import { vmTeamDirectory } from "../../../../../../services/vms/teamDirectory";

// POST /api/vm/{id}/acpmux/person-holds {nonce} (cx-0q7o slice 2d, cx-psxg):
// asks the machine's acpmux `_acpmux/person_holds {nonce}` over `acp stdio`
// and answers `{instance, proof}`. The cmux app made the nonce and checks the
// proof against its own key; this route never sees a key. Single-owner
// machines only, like the keyed start.

export const maxDuration = 60;

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/acpmux/person-holds",
    { "cmux.vm.operation": "acpmux_person_holds" },
    "/api/vm/[id]/acpmux/person-holds POST failed",
    async ({ user, span }) => {
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        body = null;
      }
      const nonce = body !== null && typeof body === "object" && !Array.isArray(body) ? (body as { nonce?: unknown }).nonce : undefined;
      if (!isAcpmuxNonce(nonce)) {
        return vmErrorResponse({
          error: "vm_acpmux_bad_nonce",
          status: 400,
          message: "The approvals check needs a nonce of 64 lowercase hex characters.",
          action: "Use \"Restart with approvals\" in the cmux app.",
          phase: "exec",
          retryable: false,
        });
      }
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      const run = await runVmRoute(acpmuxPersonHoldsVm({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        callerPlanId: account.entitlements.planId,
        teamIds: user.teamIds,
        providerVmId: id,
        teamDirectory: vmTeamDirectory(),
        nonce,
      }), { request });
      if (!run.ok) return run.response;
      setSpanAttributes(span, { "cmux.acpmux.outcome": run.value.ok ? "answered" : run.value.refusal });
      return acpmuxOutcomeResponse(run.value);
    },
  );
}
