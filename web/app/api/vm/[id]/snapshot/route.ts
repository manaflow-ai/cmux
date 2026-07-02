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
      const parsedBody = await optionalObjectBody(request);
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

type ParsedObjectBody = { ok: true; body: Record<string, unknown> } | { ok: false; response: Response };

async function optionalObjectBody(request: Request): Promise<ParsedObjectBody> {
  const raw = await request.text();
  if (!raw.trim()) return { ok: true, body: {} };
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw) as unknown;
  } catch {
    return {
      ok: false,
      response: vmErrorResponse({
        error: "vm_json_parse_failed",
        status: 400,
        message: "Cloud VM snapshot expected valid JSON.",
        action: "Send `{}` or `{ \"name\": \"before-upgrade\" }`.",
      }),
    };
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return {
      ok: false,
      response: vmErrorResponse({
        error: "vm_expected_object",
        status: 400,
        message: "Cloud VM snapshot expected a JSON object body.",
        action: "Send `{}` or `{ \"name\": \"before-upgrade\" }`.",
      }),
    };
  }
  return { ok: true, body: parsed as Record<string, unknown> };
}
