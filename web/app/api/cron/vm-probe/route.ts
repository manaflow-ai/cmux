import { getVmProbeFreshness, runVmProbe } from "../../../../services/observability/vmProbe";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 360;

export async function GET(request: Request): Promise<Response> {
  const url = new URL(request.url);
  if (url.searchParams.get("mode") === "freshness") {
    try {
      return jsonResponse(await getVmProbeFreshness());
    } catch {
      return jsonResponse({ lastSuccessAt: null, stale: true });
    }
  }

  const cronSecret = process.env.CRON_SECRET?.trim();
  if (!cronSecret) {
    return jsonResponse({ error: "cron_not_configured" }, 503);
  }

  const expected = `Bearer ${cronSecret}`;
  if (request.headers.get("authorization") !== expected) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  try {
    const probe = await runVmProbe();
    if ("skipped" in probe) return jsonResponse(probe);
    return jsonResponse({ probe });
  } catch (error) {
    return jsonResponse({
      probe: {
        status: "failure",
        error: "vm_probe_internal_error",
        message: error instanceof Error ? error.message : String(error),
      },
    });
  }
}
