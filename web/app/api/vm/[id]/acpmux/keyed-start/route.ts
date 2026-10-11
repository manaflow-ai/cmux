import {
  resolveVmRouteAccountScope,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../../services/telemetry";
import { runVmRoute } from "../../../../../../services/vms/routeWorkflow";
import { acpmuxKeyedStartVm } from "../../../../../../services/vms/acpmuxPersonKey";
import { acpmuxOutcomeResponse } from "../../../../../../services/vms/acpmuxPersonKeyRoute";
import { isAcpmuxKeyLine } from "../../../../../../services/vms/drivers/acpmuxPersonKey";
import { vmTeamDirectory } from "../../../../../../services/vms/teamDirectory";

// POST /api/vm/{id}/acpmux/keyed-start (cx-0q7o slice 2d, cx-psxg): restarts
// the machine's acpmux with the person key the cmux app made, so the app can
// allow that daemon's agent prompts from the Mac (#13742 D16).
//
// The body is the key line only: application/octet-stream, exactly 64
// lowercase hex characters and a newline. It is NON-LOGGABLE: it is read
// into one byte array that is zeroed after the provider call, it goes to the
// machine only as the stdin of the keyed start, and it is never logged,
// traced, put in an error, stored or retried. No Idempotency-Key: a request
// that did not answer is sent again by the person, with a new key.
//
// Single-owner machines only; see services/vms/acpmuxPersonKey.ts.

export const maxDuration = 120;

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/acpmux/keyed-start",
    { "cmux.vm.operation": "acpmux_keyed_start" },
    "/api/vm/[id]/acpmux/keyed-start POST failed",
    async ({ user, span }) => {
      const declared = Number(request.headers.get("content-length") ?? "65");
      const type = request.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase();
      let keyLine: Uint8Array | null = null;
      if (type === "application/octet-stream" && declared === 65) {
        try {
          keyLine = new Uint8Array(await request.arrayBuffer());
        } catch {
          keyLine = null;
        }
      }
      if (!keyLine || !isAcpmuxKeyLine(keyLine)) {
        keyLine?.fill(0);
        return vmErrorResponse({
          error: "vm_acpmux_bad_key",
          status: 400,
          message: "The request did not carry one approvals key.",
          action: "Use \"Restart with approvals\" in the cmux app.",
          phase: "exec",
          retryable: false,
        });
      }
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) {
        keyLine.fill(0);
        return account.response;
      }
      setSpanAttributes(span, { "cmux.vm.id": id });
      const run = await runVmRoute(acpmuxKeyedStartVm({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        callerPlanId: account.entitlements.planId,
        teamIds: user.teamIds,
        providerVmId: id,
        teamDirectory: vmTeamDirectory(),
        keyLine,
      }), { request });
      keyLine.fill(0);
      if (!run.ok) return run.response;
      setSpanAttributes(span, { "cmux.acpmux.outcome": run.value.ok ? "started" : run.value.refusal });
      return acpmuxOutcomeResponse(run.value);
    },
  );
}
