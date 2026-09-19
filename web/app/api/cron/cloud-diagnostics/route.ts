import { authorizeCronRequest } from "../../../../services/cronAuth";
import { maintainCloudDiagnostics } from "../../../../services/observability/cloudTelemetryDelivery";

export async function GET(request: Request): Promise<Response> {
  const auth = authorizeCronRequest(request);
  if (!auth.ok) return new Response(null, { status: auth.reason === "cron_secret_missing" ? 503 : 401 });
  const result = await maintainCloudDiagnostics();
  return new Response(JSON.stringify(result), {
    status: result.configured ? 200 : 503,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}
