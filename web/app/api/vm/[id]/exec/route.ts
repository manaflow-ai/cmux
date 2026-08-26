import {
  jsonResponse,
  notFoundVm,
  resolveVmRouteAccountScope,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { isVmNotFoundError } from "../../../../../services/vms/errors";
import { parseVmExecBody } from "../../../../../services/vms/requestSchemas";
import { execVm, runVmWorkflow } from "../../../../../services/vms/workflows";


export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/exec",
    { "cmux.vm.operation": "exec" },
    "/api/vm/[id]/exec POST failed",
    async ({ user, span }) => {
      let rawBody: unknown;
      try {
        rawBody = await request.json();
      } catch {
        return vmErrorResponse({
          error: "vm_invalid_json",
          status: 400,
          message: "Cloud VM exec expected a JSON object body.",
          action: "Send JSON like `{ \"command\": \"pwd\" }`. From the CLI, use `cmux vm exec <id> -- pwd`.",
        });
      }
      if (rawBody === null || typeof rawBody !== "object" || Array.isArray(rawBody)) {
        return vmErrorResponse({
          error: "vm_invalid_request",
          status: 400,
          message: "Cloud VM exec body must be a JSON object.",
          action: "Send JSON like `{ \"command\": \"pwd\" }`. From the CLI, use `cmux vm exec <id> -- pwd`.",
        });
      }
      const parsed = parseVmExecBody(rawBody as Record<string, unknown>);
      if (!parsed.ok) return parsed.response;
      const { command, timeoutMs } = parsed.body;

      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, {
        "cmux.vm.id": id,
        "cmux.command_length": command.length,
        "cmux.timeout_ms": timeoutMs,
      });
      try {
        const result = await runVmWorkflow(execVm({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          teamIds: user.teamIds,
          providerVmId: id,
          command,
          timeoutMs,
        }));
        setSpanAttributes(span, { "cmux.exec.exit_code": result.exitCode });
        return jsonResponse(result);
      } catch (err) {
        if (isVmNotFoundError(err)) return notFoundVm(id);
        throw err;
      }
    },
  );
}
