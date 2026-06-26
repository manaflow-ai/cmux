import {
  jsonResponse,
  notFoundVm,
  resolveVmRouteAccountScope,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { isVmNotFoundError } from "../../../../../services/vms/errors";
import { runVmWorkflow, snapshotVm } from "../../../../../services/vms/workflows";

export const dynamic = "force-dynamic";

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
      const body = await optionalObjectBody(request);
      if (body === null) {
        return vmErrorResponse({
          error: "vm_invalid_request",
          status: 400,
          message: "Cloud VM snapshot expected a JSON object body.",
          action: "Send `{}` or `{ \"name\": \"before-upgrade\" }`.",
        });
      }
      const name = typeof body.name === "string" && body.name.trim() ? body.name.trim() : undefined;
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id, "cmux.snapshot.named": !!name });
      try {
        const snapshot = await runVmWorkflow(snapshotVm({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
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

async function optionalObjectBody(request: Request): Promise<Record<string, unknown> | null> {
  const raw = await request.text();
  if (!raw.trim()) return {};
  const parsed = JSON.parse(raw) as unknown;
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  return parsed as Record<string, unknown>;
}
