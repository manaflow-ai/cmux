import {
  jsonResponse,
  notFoundVm,
  resolveVmRouteAccountScope,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { isVmNotFoundError } from "../../../../../services/vms/errors";
import { openVmPort, runVmWorkflow } from "../../../../../services/vms/workflows";


export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/open-port",
    { "cmux.vm.operation": "open_port" },
    "/api/vm/[id]/open-port POST failed",
    async ({ user, span }) => {
      let rawBody: unknown;
      try {
        rawBody = await request.json();
      } catch {
        return vmErrorResponse({
          error: "vm_invalid_json",
          status: 400,
          message: "Cloud VM open-port expected a JSON object body.",
          action: "Send JSON like `{ \"port\": 3000 }`. From the CLI, use `cmux vm open <id> <port>`.",
        });
      }
      if (rawBody === null || typeof rawBody !== "object" || Array.isArray(rawBody)) {
        return vmErrorResponse({
          error: "vm_invalid_request",
          status: 400,
          message: "Cloud VM open-port body must be a JSON object.",
          action: "Send JSON like `{ \"port\": 3000 }`. From the CLI, use `cmux vm open <id> <port>`.",
        });
      }
      const body = rawBody as { port?: unknown };
      const port = typeof body.port === "number" && Number.isInteger(body.port) ? body.port : 0;
      if (port < 1 || port > 65535) {
        return vmErrorResponse({
          error: "vm_invalid_port",
          status: 400,
          message: "`port` is required and must be an integer between 1 and 65535.",
          action: "Pass the HTTP port your server listens on, for example `cmux vm open <id> 3000`.",
          details: { field: "port" },
        });
      }

      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id, "cmux.vm.port": port });
      try {
        const endpoint = await runVmWorkflow(openVmPort({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          teamIds: user.teamIds,
          providerVmId: id,
          port,
        }));
        return jsonResponse(endpoint);
      } catch (err) {
        if (isVmNotFoundError(err)) return notFoundVm(id);
        throw err;
      }
    },
  );
}
