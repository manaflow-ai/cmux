import { authorizeCronRequest } from "../../../../services/cronAuth";
import { pruneExpiredDeviceTokenRevocations } from "../../../../services/apns/deviceRevocationRetention";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

export async function GET(request: Request): Promise<Response> {
  const auth = authorizeCronRequest(request);
  if (!auth.ok && auth.reason === "cron_secret_missing") {
    return jsonResponse({ error: "service_unavailable" }, 503);
  }
  if (!auth.ok) return jsonResponse({ error: "unauthorized" }, 401);
  try {
    const deleted = await pruneExpiredDeviceTokenRevocations();
    return jsonResponse({ ok: true, deleted });
  } catch {
    return jsonResponse({ error: "push_revocation_retention_failed" }, 500);
  }
}
