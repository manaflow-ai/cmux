import {
  jsonResponse,
  resolveVmRouteAccountScope,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { parseMachineHygieneRequest, runMachineHygiene } from "../../../../../services/vms/hygiene/workflow";

// Disk hygiene for one of the caller's own machines (cmux-machine-hygiene).
// The body is optional: `{}` or no body is a dry-run that only reports what
// could be reclaimed; `{ "apply": true }` reclaims it. Clients show the
// dry-run first and offer apply as its own, separately confirmed action.
// Only the machine's owner may call it, and a paused machine is never woken.

// The script's own timeout (MACHINE_HYGIENE_TIMEOUT_MS) plus auth and exec overhead.
export const maxDuration = 300;

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/hygiene",
    { "cmux.vm.operation": "hygiene" },
    "/api/vm/[id]/hygiene POST failed",
    async ({ user, span }) => {
      const text = await request.text();
      let rawBody: unknown;
      try {
        rawBody = text.trim() ? JSON.parse(text) : undefined;
      } catch {
        return vmErrorResponse({
          error: "vm_invalid_json",
          status: 400,
          message: "Cloud VM cleanup expected a JSON object body, or no body.",
          action: "Send `{}` for a dry-run or `{ \"apply\": true }` to clean.",
        });
      }
      const parsed = parseMachineHygieneRequest(rawBody);
      if (!parsed) {
        return vmErrorResponse({
          error: "vm_invalid_request",
          status: 400,
          message: "`apply` must be omitted, false, or true.",
          action: "Send `{}` for a dry-run or `{ \"apply\": true }` to clean.",
          details: { field: "apply" },
        });
      }
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id, "cmux.vm.hygiene.apply": parsed.apply });
      const run = await runVmRoute(runMachineHygiene({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        apply: parsed.apply,
      }), { request });
      if (!run.ok) return run.response;
      const outcome = run.value;
      if (outcome.kind === "not-running") {
        return vmErrorResponse({
          error: "vm_not_running",
          status: 409,
          message: `The machine is ${outcome.status}. Cleanup never wakes a machine.`,
          action: "Resume the machine, then run cleanup again.",
          retryable: false,
          details: { status: outcome.status },
        });
      }
      if (outcome.kind === "busy") {
        return vmErrorResponse({
          error: "vm_hygiene_busy",
          status: 409,
          message: "Another cleanup is already running on this machine.",
          action: "Wait for it to finish, then run cleanup again.",
          retryable: true,
        });
      }
      if (outcome.kind === "failed") {
        return vmErrorResponse({
          error: "vm_hygiene_failed",
          status: 500,
          message: "The cleanup script did not return a report.",
          action: "Run the dry-run again; if it keeps failing, contact support.",
          retryable: false,
          details: { exitCode: outcome.exitCode, detail: outcome.detail },
        });
      }
      setSpanAttributes(span, {
        "cmux.vm.hygiene.reclaimable_kb": outcome.report.reclaimableKb,
        "cmux.vm.hygiene.items": outcome.report.items.length,
      });
      return jsonResponse({ id, ...outcome.report });
    },
  );
}
