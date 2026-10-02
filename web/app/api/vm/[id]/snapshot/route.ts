import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { snapshotVm } from "../../../../../services/vms/workflows";
import { parseOptionalObjectBody } from "../../../../../services/vms/routeInput";

// Snapshot duration scales with the machine's dirty memory; give it the same
// long-provisioning budget as create (see app/api/vm/route.ts).
export const maxDuration = 600;

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/snapshot",
    { "cmux.vm.operation": "snapshot" },
    "/api/vm/[id]/snapshot POST failed",
    async ({ user, span }) => {
      const parsedBody = await parseOptionalObjectBody(request, {
        operation: "snapshot",
        action: "Send `{}` or `{ \"name\": \"before-upgrade\" }`.",
      });
      if (!parsedBody.ok) return parsedBody.response;
      const body = parsedBody.body;
      const name = typeof body.name === "string" && body.name.trim() ? body.name.trim() : undefined;
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id, "cmux.snapshot.named": !!name });
      const run = await runVmRoute(snapshotVm({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        name,
      }), { request });
      if (!run.ok) return run.response;
      const snapshot = run.value;
      return jsonResponse({ snapshotId: snapshot.id, id: snapshot.id, name: snapshot.name ?? null, createdAt: snapshot.createdAt });
    },
  );
}
