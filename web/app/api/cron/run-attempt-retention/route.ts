import { authorizeCronRequest } from "../../../../services/cronAuth";
import { reapExpiredCloudVmAttempts } from "../../../../services/runs/dogfood";

export const maxDuration = 60;

/** Destroy cloud VMs after their short terminal attachment window expires. */
export async function GET(request: Request): Promise<Response> {
  const auth = authorizeCronRequest(request);
  if (!auth.ok) return Response.json({ error: "unauthorized" }, { status: 401 });
  try {
    const result = await reapExpiredCloudVmAttempts({ limit: 20 });
    return Response.json({ ok: result.errors === 0, ...result }, { status: result.errors === 0 ? 200 : 503 });
  } catch (error) {
    console.error("[runs] terminal retention job failed", error);
    return Response.json({ error: "run_attempt_retention_failed" }, { status: 503 });
  }
}
