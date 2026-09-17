import { parseVmExecBody } from "../../../../../services/vms/requestSchemas";
import {
  jsonResponse,
  resolveVmRouteAccountScope,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { execVm } from "../../../../../services/vms/workflows";


// Exec accepts client timeouts up to 15 minutes (MAX_EXEC_TIMEOUT_MS below).
// The function budget must outlive that ceiling or the platform kills the
// invocation mid-command; 960s = the 900s command ceiling plus attach and
// auth overhead.
export const maxDuration = 960;

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
      const commandBytes = Buffer.byteLength(command, "utf8");
      const MAX_PROVIDER_COMMAND_BYTES = 64 * 1024;
      if (commandBytes > MAX_PROVIDER_COMMAND_BYTES) {
        return vmErrorResponse({
          error: "vm_command_too_large",
          status: 413,
          message: `Cloud VM commands must be 64 KiB or smaller. This command is ${commandBytes} bytes.`,
          action: "Split the command into smaller requests or upload a script and execute the script path.",
          phase: "exec",
          retryable: false,
          details: { commandBytes, maxCommandBytes: MAX_PROVIDER_COMMAND_BYTES },
        });
      }

      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, {
        "cmux.vm.id": id,
        "cmux.command_length": commandBytes,
        "cmux.timeout_ms": timeoutMs,
      });
      const run = await runVmRoute(execVm({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        maxActiveVms: account.entitlements.maxActiveVms,
        callerPlanId: account.entitlements.planId,
        teamIds: user.teamIds,
        providerVmId: id,
        command,
        timeoutMs,
      }), { request });
      if (!run.ok) return run.response;
      const result = run.value;
      setSpanAttributes(span, { "cmux.exec.exit_code": result.exitCode });
      return jsonResponse(result);
    },
  );
}
