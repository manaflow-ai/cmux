import { authorizeCronRequest } from "../../../../services/cronAuth";
import { maintainCloudDiagnostics } from "../../../../services/observability/cloudTelemetryDelivery";
import { reportCronFailure, runMonitoredCron } from "../../../../services/observability/cronMonitor";

export async function GET(request: Request): Promise<Response> {
  const auth = authorizeCronRequest(request);
  if (!auth.ok) return new Response(null, { status: auth.reason === "cron_secret_missing" ? 503 : 401 });
  return runMonitoredCron("cloud-diagnostics", async () => {
    try {
      const result = await maintainCloudDiagnostics();
      if (!result.configured) {
        reportCronFailure(
          "cloud-diagnostics",
          new Error("Cloud diagnostics delivery is not configured"),
          {},
          { stage: "unconfigured", level: "warning" },
        );
      }
      return jsonNoStore(result, result.configured ? 200 : 503);
    } catch (error) {
      reportCronFailure("cloud-diagnostics", error);
      return jsonNoStore({ error: "cloud_diagnostics_failed" }, 500);
    }
  });
}

function jsonNoStore(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}
