import { authorizeCronRequest } from "../../../../services/cronAuth";
import { runVmWorkflow } from "../../../../services/vms/workflows";
import { cleanupEnvLayers } from "../../../../services/vms/workflows";

export const maxDuration = 300;

export async function GET(request: Request): Promise<Response> {
  return handle(request);
}

export async function POST(request: Request): Promise<Response> {
  return handle(request);
}

async function handle(request: Request): Promise<Response> {
  const auth = authorizeCronRequest(request);
  if (!auth.ok && auth.reason === "cron_secret_missing") {
    return Response.json({ error: "service_unavailable" }, { status: 503 });
  }
  if (!auth.ok) return Response.json({ error: "unauthorized" }, { status: 401 });

  try {
    const retention = await runVmWorkflow(cleanupEnvLayers());
    return Response.json({ ok: true, retention });
  } catch (error) {
    console.error("[VM] env-layer retention failed", error);
    return Response.json({ error: "vm_env_retention_failed" }, { status: 500 });
  }
}
