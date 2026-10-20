import { jsonResponse } from "@/services/vms/routeHelpers";
import { revokeExpiredIdentityLeases, runVmWorkflow } from "@/services/vms/workflows";
import { authorizeCronRequest } from "@/services/cronAuth";


export async function GET(request: Request): Promise<Response> {
  return handle(request);
}

export async function POST(request: Request): Promise<Response> {
  return handle(request);
}

async function handle(request: Request): Promise<Response> {
  const auth = authorizeCronRequest(request);
  if (!auth.ok && auth.reason === "cron_secret_missing") {
    console.error("vm.leases.revoke_expired.cron_secret_missing");
    return jsonResponse({ error: "service_unavailable" }, 503);
  }
  if (!auth.ok) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  const revoked = await runVmWorkflow(revokeExpiredIdentityLeases());
  return jsonResponse({ ok: true, revoked });
}
