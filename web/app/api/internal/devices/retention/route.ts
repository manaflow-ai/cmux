import { timingSafeEqual } from "node:crypto";
import {
  DEVICE_RETENTION_MAX_DURATION_MS,
  DEVICE_RETENTION_MAX_ROWS,
  pruneStaleDeviceRegistryRows,
} from "../../../../../services/devices/retention";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";


export async function GET(request: Request): Promise<Response> {
  return handle(request);
}

export async function POST(request: Request): Promise<Response> {
  return handle(request);
}

async function handle(request: Request): Promise<Response> {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret) return jsonResponse({ error: "service_unavailable" }, 503);
  const authorization = request.headers.get("authorization")?.trim() ?? "";
  const token = authorization.toLowerCase().startsWith("bearer ")
    ? authorization.slice("bearer ".length).trim()
    : "";
  const tokenBytes = Buffer.from(token);
  const secretBytes = Buffer.from(secret);
  if (tokenBytes.length !== secretBytes.length || !timingSafeEqual(tokenBytes, secretBytes)) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  try {
    const startedAt = Date.now();
    const retention = await pruneStaleDeviceRegistryRows({
      now: new Date(),
      maxRows: DEVICE_RETENTION_MAX_ROWS,
      maxDurationMs: DEVICE_RETENTION_MAX_DURATION_MS,
    });
    console.info("device registry retention cleanup completed", {
      rows_processed: retention.rowsProcessed,
      batches: retention.batches,
      backlog: retention.backlog,
      budget_exhausted: retention.budgetExhausted,
      by_category: retention.byCategory,
      duration_ms: Date.now() - startedAt,
    });
    return jsonResponse({ ok: true, retention });
  } catch {
    console.error("device registry retention cleanup failed", { failure: "database" });
    return jsonResponse({ error: "devices_retention_failed" }, 500);
  }
}
