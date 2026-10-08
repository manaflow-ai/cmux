import { runCatalogCron } from "../../../../services/model-catalog/cron";
import { databaseCatalogRepo } from "../../../../services/model-catalog/repo";
import { authorizeCronRequest } from "../../../../services/cronAuth";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

/** Vercel Cron: models.dev -> models_dev_snapshots (on change) -> catalog_versions (on change). */
export async function GET(request: Request): Promise<Response> {
  const auth = authorizeCronRequest(request);
  if (!auth.ok && auth.reason === "cron_secret_missing") return jsonResponse({ error: "service_unavailable" }, 503);
  if (!auth.ok) return jsonResponse({ error: "unauthorized" }, 401);
  try {
    const result = await runCatalogCron(databaseCatalogRepo());
    return jsonResponse(result, result.ok ? 200 : 422);
  } catch (error) {
    console.warn("model catalog cron failed", error instanceof Error ? error.message : String(error));
    return jsonResponse({ error: "model_catalog_refresh_failed" }, 502);
  }
}
