import {
  jsonResponse,
  notFoundVm,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { isVmNotFoundError } from "../../../../../services/vms/errors";
import { runVmWorkflow, snapshotVm } from "../../../../../services/vms/workflows";
import { parseOptionalObjectBody } from "../../../../../services/vms/routeInput";

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
      try {
        const snapshot = await runVmWorkflow(snapshotVm({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          teamIds: user.teamIds,
          providerVmId: id,
          name,
        }));
        return jsonResponse({ snapshotId: snapshot.id, id: snapshot.id, name: snapshot.name ?? null, createdAt: snapshot.createdAt });
      } catch (err) {
        if (isVmNotFoundError(err)) return notFoundVm(id);
        throw err;
      }
    },
  );
}
