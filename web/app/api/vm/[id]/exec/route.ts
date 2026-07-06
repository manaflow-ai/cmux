import {
  jsonResponse,
  notFoundVm,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { isVmNotFoundError } from "../../../../../services/vms/errors";
import { execVm, runVmWorkflow } from "../../../../../services/vms/workflows";

export const dynamic = "force-dynamic";

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
      const body = rawBody as { command?: unknown; timeoutMs?: unknown };
      const command = typeof body.command === "string" ? body.command.trim() : "";
      if (command.length === 0) {
        return vmErrorResponse({
          error: "vm_invalid_command",
          status: 400,
          message: "`command` is required and must be a non-empty string.",
          action: "Pass a shell command, for example `cmux vm exec <id> -- uname -a`.",
          details: { field: "command" },
        });
      }
      // Clamp the timeout so a client can't tie up provider quota on a runaway exec. Upper
      // bound matches the provider defaults (15 min on Freestyle); negative / non-number
      // values fall back to 30s.
      const MAX_EXEC_TIMEOUT_MS = 15 * 60 * 1000;
      const rawTimeout = body.timeoutMs;
      const timeoutMs = typeof rawTimeout === "number" && Number.isFinite(rawTimeout) && rawTimeout > 0
        ? Math.min(Math.floor(rawTimeout), MAX_EXEC_TIMEOUT_MS)
        : 30_000;

      const { id } = await params;
      setSpanAttributes(span, {
        "cmux.vm.id": id,
        "cmux.command_length": command.length,
        "cmux.timeout_ms": timeoutMs,
      });
      try {
        const result = await runVmWorkflow(execVm({
          userId: user.id,
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
    { requireAllTeams: true },
  );
}
