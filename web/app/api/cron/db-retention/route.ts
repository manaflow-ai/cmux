import { authorizeCronRequest } from "../../../../services/cronAuth";
import { drainTableRetention } from "../../../../services/retention/drain";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

// The drain's own time budget is 20 s; this only guards a hung connection.
export const maxDuration = 60;

export async function GET(request: Request): Promise<Response> {
  return handle(request);
}

export async function POST(request: Request): Promise<Response> {
  return handle(request);
}

async function handle(request: Request): Promise<Response> {
  const auth = authorizeCronRequest(request);
  if (!auth.ok && auth.reason === "cron_secret_missing") {
    return jsonResponse({ error: "service_unavailable" }, 503);
  }
  if (!auth.ok) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  try {
    const startedAt = Date.now();
    const retention = await drainTableRetention({ now: new Date() });
    console.info("db retention drain completed", {
      rows_deleted: retention.rowsDeleted,
      batches: retention.batches,
      budget_exhausted: retention.budgetExhausted,
      by_table: retention.byTable,
      duration_ms: Date.now() - startedAt,
    });
    return jsonResponse({ ok: true, retention });
  } catch {
    console.error("db retention drain failed", { failure: "database" });
    return jsonResponse({ error: "db_retention_failed" }, 500);
  }
}
