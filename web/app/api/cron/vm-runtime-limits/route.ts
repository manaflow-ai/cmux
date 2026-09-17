import { authorizeCronRequest } from "../../../../services/cronAuth";
import { enforceGoRuntimeLimits } from "../../../../services/vms/goRuntimeLimits";
import { runVmWorkflow } from "../../../../services/vms/workflows";

export const maxDuration = 60;

export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) return Response.json({ error: "unauthorized" }, { status: 401 });
  try {
    const result = await runVmWorkflow(enforceGoRuntimeLimits());
    return Response.json({ ok: result.errors === 0, ...result }, { status: result.errors ? 503 : 200 });
  } catch (error) {
    console.error("[VM] runtime limit job failed", error);
    return Response.json({ error: "vm_runtime_limits_failed" }, { status: 503 });
  }
}
