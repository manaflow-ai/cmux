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
// The body is the key line only: application/octet-stream, a declared
// Content-Length of 65, exactly 64 lowercase hex characters and a newline.
// It is NON-LOGGABLE: it goes to the machine only as the stdin of the keyed
// start, and it is never logged, traced, put in an error, stored or retried.
// The byte array this route reads is zeroed after the provider call. Other
// copies that nobody zeroes exist for the life of the request: undici's
// buffers and the JS base64 and JSON strings of the provider call. They stay
// inside the trusted delivery boundary (#13742 D16 update 4). No Idempotency-Key: a request
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
      // A body of unknown length (chunked) is never read: only a declared 65 bytes.
      const declared = request.headers.get("content-length");
      if (declared === null) {
        return vmErrorResponse({
          error: "vm_acpmux_length_required",
          status: 411,
          message: "The request did not say its length.",
          action: "Use \"Restart with approvals\" in the cmux app.",
          phase: "exec",
          retryable: false,
        });
      }
      const type = request.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase();
      let keyLine: Uint8Array | null = null;
      if (type === "application/octet-stream" && declared.trim() === "65") {
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
