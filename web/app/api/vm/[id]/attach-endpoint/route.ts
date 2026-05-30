import {
  jsonResponse,
  notFoundVm,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { isVmNotFoundError } from "../../../../../services/vms/errors";
import { openAttachEndpoint, runVmWorkflow } from "../../../../../services/vms/workflows";

export const dynamic = "force-dynamic";

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/attach-endpoint",
    { "cmux.vm.operation": "open_attach" },
    "/api/vm/[id]/attach-endpoint failed",
    async ({ user, span }) => {
      const { id } = await params;
      const body = await parseAttachBody(request);
      const requireDaemon = body.requireDaemon === true || body.require_daemon === true;
      setSpanAttributes(span, { "cmux.vm.id": id });
      setSpanAttributes(span, { "cmux.vm.attach.require_daemon": requireDaemon });
      try {
        const endpoint = await runVmWorkflow(openAttachEndpoint({
          userId: user.id,
          providerVmId: id,
          options: { requireDaemon },
        }));
        setSpanAttributes(span, { "cmux.vm.attach.transport": endpoint.transport });
        return jsonResponse(endpoint);
      } catch (err) {
        if (isVmNotFoundError(err)) return notFoundVm(id);
        throw err;
      }
    },
  );
}

async function parseAttachBody(request: Request): Promise<Record<string, unknown>> {
  try {
    const body = await request.json();
    return body && typeof body === "object" && !Array.isArray(body)
      ? body as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}
