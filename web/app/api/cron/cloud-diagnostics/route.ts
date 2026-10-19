import { authorizeCronRequest } from "../../../../services/cronAuth";
import { maintainCloudDiagnostics } from "../../../../services/observability/cloudTelemetryDelivery";
import { reportCronFailure, runMonitoredCron } from "../../../../services/observability/cronMonitor";

export async function GET(request: Request): Promise<Response> {
  const auth = authorizeCronRequest(request);
  if (!auth.ok) return new Response(null, { status: auth.reason === "cron_secret_missing" ? 503 : 401 });
  return runMonitoredCron("cloud-diagnostics", async () => {
    try {
      const result = await maintainCloudDiagnostics();
      if (result.configured) return jsonNoStore(result, 200);
      // A deployment without Cloud Axiom delivery is a deliberate setup, not
      // a failure: the caller still sees 503, but the monitor stays healthy
      // and no Sentry issue opens.
      console.warn("cmux.cron.cloud_diagnostics.unconfigured");
      return { response: jsonNoStore(result, 503), checkInStatus: "ok" as const };
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
